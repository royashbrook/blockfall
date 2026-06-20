// ============================================================================
// Blockfall — Track H: reliable-UDP networking layer implementation
// (engine/src/net.cpp)
// ============================================================================
#include "blockcore/net.hpp"

#include <algorithm>
#include <cassert>
#include <cstring>

// ---------------------------------------------------------------------------
// Platform: on non-socket builds (CI tests) stub out the POSIX layer so the
// file still compiles without syscall headers.
// ---------------------------------------------------------------------------
#ifndef BF_NO_SOCKETS
#  include <arpa/inet.h>
#  include <fcntl.h>
#  include <netdb.h>
#  include <netinet/in.h>
#  include <sys/socket.h>
#  include <unistd.h>
#  include <cerrno>
#endif

namespace bf {

// ===========================================================================
// Helpers: little-endian read/write (C++23 portable, no UB)
// ===========================================================================
namespace {

void write_u16_le(std::byte* p, std::uint16_t v) {
    p[0] = std::byte(v & 0xFFu);
    p[1] = std::byte((v >> 8) & 0xFFu);
}
void write_u32_le(std::byte* p, std::uint32_t v) {
    p[0] = std::byte(v & 0xFFu);
    p[1] = std::byte((v >>  8) & 0xFFu);
    p[2] = std::byte((v >> 16) & 0xFFu);
    p[3] = std::byte((v >> 24) & 0xFFu);
}
std::uint16_t read_u16_le(const std::byte* p) {
    return static_cast<std::uint16_t>(
        (static_cast<std::uint16_t>(std::to_integer<std::uint8_t>(p[0])))
      | (static_cast<std::uint16_t>(std::to_integer<std::uint8_t>(p[1])) << 8));
}
std::uint32_t read_u32_le(const std::byte* p) {
    return (static_cast<std::uint32_t>(std::to_integer<std::uint8_t>(p[0])))
         | (static_cast<std::uint32_t>(std::to_integer<std::uint8_t>(p[1])) <<  8)
         | (static_cast<std::uint32_t>(std::to_integer<std::uint8_t>(p[2])) << 16)
         | (static_cast<std::uint32_t>(std::to_integer<std::uint8_t>(p[3])) << 24);
}

// Sequence-number comparison: seq A is "before" seq B in a wrapping sense if
// the unsigned difference B-A < 2^31.  This handles 32-bit wraparound.
bool seq_before(std::uint32_t a, std::uint32_t b) {
    return static_cast<std::int64_t>(b) - static_cast<std::int64_t>(a) > 0
        || (b < a && (a - b) >= 0x8000'0000u);
}

} // anonymous namespace

// ===========================================================================
// ReliableEndpoint — implementation
// ===========================================================================

// ---------------------------------------------------------------------------
// parse_header — validate magic/version and unpack all fields.
// Returns false if the datagram is too short or has wrong magic/version.
// ---------------------------------------------------------------------------
bool ReliableEndpoint::parse_header(std::span<const std::byte> data, Header& out)
{
    if (data.size() < kNetHeaderSize) return false;

    const std::byte* p = data.data();

    // Magic: 'B','F','N','W'
    if (std::to_integer<char>(p[0]) != 'B' ||
        std::to_integer<char>(p[1]) != 'F' ||
        std::to_integer<char>(p[2]) != 'N' ||
        std::to_integer<char>(p[3]) != 'W') return false;

    // Version
    std::uint16_t ver = read_u16_le(p + 4);
    if (ver != kNetVersion) return false;

    out.channel     = std::to_integer<std::uint8_t>(p[6]);
    out.flags       = std::to_integer<std::uint8_t>(p[7]);
    out.seq         = read_u32_le(p + 8);
    out.ack         = read_u32_le(p + 12);
    out.ack_bits    = read_u32_le(p + 16);
    out.peer_id     = read_u16_le(p + 20);
    out.payload_len = read_u16_le(p + 22);

    // Sanity: payload must fit
    if (kNetHeaderSize + out.payload_len > data.size()) return false;

    return true;
}

// ---------------------------------------------------------------------------
// write_header — serialise the BFNW header into buf (which must already have
// capacity for at least kNetHeaderSize + payload_len bytes).  The method uses
// the current ack/ack_bits state.
// ---------------------------------------------------------------------------
void ReliableEndpoint::write_header(std::vector<std::byte>& buf, NetChannel ch,
                                    std::uint8_t flags, std::uint32_t seq,
                                    std::uint16_t payload_len) const
{
    // Resize to hold header (payload bytes appended by caller afterwards).
    buf.resize(kNetHeaderSize);
    std::byte* p = buf.data();

    p[0] = std::byte('B');
    p[1] = std::byte('F');
    p[2] = std::byte('N');
    p[3] = std::byte('W');
    write_u16_le(p + 4, kNetVersion);
    p[6] = std::byte(static_cast<std::uint8_t>(ch));
    p[7] = std::byte(flags);
    write_u32_le(p + 8,  seq);
    write_u32_le(p + 12, rel_cum_ack_);
    write_u32_le(p + 16, rel_cum_bits_);
    write_u16_le(p + 20, peer_id_);
    write_u16_le(p + 22, payload_len);
}

// ---------------------------------------------------------------------------
// transmit_datagram — pass a fully-formed datagram to the sink and clear the
// dirty-ack flag (the ack is now piggybacked).
// ---------------------------------------------------------------------------
void ReliableEndpoint::transmit_datagram(std::vector<std::byte>& buf)
{
    sink_(std::span<const std::byte>(buf.data(), buf.size()));
    ack_dirty_ = false;
}

// ---------------------------------------------------------------------------
// send — build a BFNW datagram, store a copy for reliable channels, transmit.
// ---------------------------------------------------------------------------
void ReliableEndpoint::send(NetChannel ch, std::span<const std::byte> payload)
{
    const std::uint32_t seq = (ch == NetChannel::Unreliable) ? next_unrel_seq_out_++
                                                             : next_seq_out_++;
    const std::uint16_t plen = static_cast<std::uint16_t>(
        std::min(payload.size(), static_cast<std::size_t>(0xFFFFu)));

    std::vector<std::byte> buf;
    write_header(buf, ch, 0, seq, plen);
    buf.insert(buf.end(),
               payload.data(),
               payload.data() + plen);

    if (ch == NetChannel::ReliableOrdered || ch == NetChannel::ReliableUnordered) {
        UnackedPacket pkt;
        pkt.seq     = seq;
        pkt.channel = ch;
        pkt.sent_at = last_update_;
        pkt.datagram = buf;   // copy full datagram (header + payload)
        unacked_.push_back(std::move(pkt));
    }

    transmit_datagram(buf);
}

// ---------------------------------------------------------------------------
// process_acks — remove entries from unacked_ that the remote has confirmed.
//
// Wire semantics: `remote_ack` is the cumulative ack — the remote has received
// ALL seqs in the range [1 .. remote_ack].  `remote_ack_bits` is a bitmask
// of up to 32 seqs ABOVE remote_ack that have also been received (out-of-order
// arrives on reliable-unordered or future packets).  Bit k (0-indexed) of
// remote_ack_bits means seq (remote_ack + k + 1) was received.
// ---------------------------------------------------------------------------
void ReliableEndpoint::process_acks(std::uint32_t remote_ack,
                                    std::uint32_t remote_ack_bits)
{
    if (remote_ack == 0) return;

    // A seq `s` is acked if:
    //   1. s <= remote_ack  (cumulative: all below the frontier are confirmed)
    //   2. OR bit (s - remote_ack - 1) in remote_ack_bits is set (out-of-order above)
    auto is_acked = [&](std::uint32_t s) -> bool {
        // Cumulative: everything up to and including remote_ack is acked.
        if (!seq_before(remote_ack, s)) return true;   // s <= remote_ack
        // Out-of-order above frontier
        std::uint32_t delta = s - remote_ack;           // s > remote_ack, delta >= 1
        if (delta > 32u) return false;
        return (remote_ack_bits & (std::uint32_t{1} << (delta - 1u))) != 0;
    };

    auto it = unacked_.begin();
    while (it != unacked_.end()) {
        if (is_acked(it->seq)) {
            it = unacked_.erase(it);
        } else {
            ++it;
        }
    }
}

// ---------------------------------------------------------------------------
// already_received / mark_received — dedup for ReliableUnordered.
// Uses a sliding bitmask window of 64 around received_unord_max_.
// ---------------------------------------------------------------------------
// already_received / mark_received — dedup for ReliableUnordered.
// Uses an unordered_map as a sliding set, pruned when entries fall more than
// kUnordDedupWindow behind the current max.  This handles burst sends of any
// size without a fixed bitmask-window limit.
bool ReliableEndpoint::already_received(std::uint32_t seq) const
{
    if (received_unord_max_ != 0) {
        // If seq is more than kUnordDedupWindow behind the current max, the
        // sender won't resend it (it has been acked); treat as seen.
        if (!seq_before(received_unord_max_, seq)) {
            std::uint32_t delta = received_unord_max_ - seq;
            if (delta > kUnordDedupWindow) return true;
        }
    }
    return received_unord_set_.count(seq) != 0;
}

void ReliableEndpoint::mark_received(std::uint32_t seq)
{
    received_unord_set_[seq] = true;

    // Advance the max.
    if (received_unord_max_ == 0 || seq_before(received_unord_max_, seq)) {
        received_unord_max_ = seq;
    }

    // Prune entries older than kUnordDedupWindow behind the current max.
    if (received_unord_max_ > kUnordDedupWindow) {
        std::uint32_t cutoff = received_unord_max_ - kUnordDedupWindow;
        for (auto it = received_unord_set_.begin();
             it != received_unord_set_.end(); ) {
            // Only prune seqs that are clearly below the cutoff in a
            // wrapping-safe sense.
            if (!seq_before(cutoff, it->first) && it->first != cutoff
                && !seq_before(received_unord_max_, it->first)) {
                it = received_unord_set_.erase(it);
            } else {
                ++it;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// try_deliver_ordered — attempt to flush contiguous seq from reorder_buf_.
// ---------------------------------------------------------------------------
void ReliableEndpoint::try_deliver_ordered(std::uint32_t seq,
                                           std::span<const std::byte> payload)
{
    // Store this arrival in the reorder buffer.
    if (reorder_buf_.find(seq) == reorder_buf_.end()) {
        reorder_buf_[seq] = std::vector<std::byte>(payload.begin(), payload.end());
    }

    // Drain contiguous run starting at next_expected_ord_.
    while (true) {
        auto it = reorder_buf_.find(next_expected_ord_);
        if (it == reorder_buf_.end()) break;
        if (receiver_) {
            receiver_(NetChannel::ReliableOrdered,
                      std::span<const std::byte>(it->second.data(), it->second.size()));
        }
        reorder_buf_.erase(it);
        ++next_expected_ord_;
    }
}

// ---------------------------------------------------------------------------
// on_datagram — parse incoming BFNW datagram, process acks, deliver payload.
// ---------------------------------------------------------------------------
void ReliableEndpoint::on_datagram(std::span<const std::byte> bytes)
{
    Header h;
    if (!parse_header(bytes, h)) return;

    // Process acks from remote (clear our unacked set).
    // This must happen BEFORE the ack-only early return.
    if (h.ack != 0) {
        process_acks(h.ack, h.ack_bits);
    }

    // Ack-only datagrams carry no application payload.
    if ((h.flags & kFlagAckOnly) != 0u || h.payload_len == 0) return;
    if (h.seq == 0) return;

    auto payload = bytes.subspan(kNetHeaderSize, h.payload_len);
    auto ch      = static_cast<NetChannel>(h.channel);

    // ---- Update cumulative ack tracking for reliable channels ---------------
    // We maintain rel_cum_ack_ = the highest N such that all seqs 1..N have
    // been received on reliable channels.  rel_cum_bits_ marks which of the 32
    // seqs immediately above rel_cum_ack_ have also been received.
    // This guarantees old seqs never "fall out" of the ack window on the sender.
    if (ch == NetChannel::ReliableOrdered || ch == NetChannel::ReliableUnordered) {
        received_rel_set_[h.seq] = true;

        // Advance cumulative ack as far as possible.
        while (received_rel_set_.count(rel_cum_ack_ + 1u) != 0) {
            ++rel_cum_ack_;
            // Shift the out-of-order bits: the first bit now falls out.
            rel_cum_bits_ >>= 1u;
        }

        // Mark the current seq in rel_cum_bits_ if it's in the 1..32 range above
        // the cumulative ack.
        if (h.seq > rel_cum_ack_) {
            std::uint32_t delta = h.seq - rel_cum_ack_;
            if (delta <= 32u) {
                rel_cum_bits_ |= (std::uint32_t{1} << (delta - 1u));
            }
        }

        // Prune received_rel_set_ entries below the cumulative ack (they're acked).
        if (rel_cum_ack_ > 0) {
            for (auto it = received_rel_set_.begin(); it != received_rel_set_.end(); ) {
                if (!seq_before(rel_cum_ack_, it->first) && it->first != rel_cum_ack_ + 1u) {
                    it = received_rel_set_.erase(it);
                } else {
                    ++it;
                }
            }
        }

        ack_dirty_ = true;
    }

    // ---- Deliver payload ----------------------------------------------------
    if (!receiver_) return;

    switch (ch) {
    case NetChannel::ReliableOrdered:
        try_deliver_ordered(h.seq, payload);
        break;

    case NetChannel::ReliableUnordered:
        if (!already_received(h.seq)) {
            mark_received(h.seq);
            receiver_(NetChannel::ReliableUnordered, payload);
        }
        break;

    case NetChannel::Unreliable:
        // Deliver only if seq is strictly newer than the last delivered.
        if (last_unreliable_seq_ == 0 || seq_before(last_unreliable_seq_, h.seq)) {
            last_unreliable_seq_ = h.seq;
            receiver_(NetChannel::Unreliable, payload);
        }
        break;

    default:
        break;
    }
}

// ---------------------------------------------------------------------------
// update — resend timed-out reliable packets; emit standalone acks if needed.
// ---------------------------------------------------------------------------
void ReliableEndpoint::update(double now_seconds)
{
    last_update_ = now_seconds;

    // Resend timed-out reliable packets.
    for (auto& pkt : unacked_) {
        if (now_seconds - pkt.sent_at >= kResendTimeoutSec) {
            // Patch the ack/ack_bits fields with current cumulative ack state
            // so each resend carries fresh piggyback information.
            if (pkt.datagram.size() >= kNetHeaderSize) {
                std::byte* p = pkt.datagram.data();
                write_u32_le(p + 12, rel_cum_ack_);
                write_u32_le(p + 16, rel_cum_bits_);
            }
            pkt.sent_at = now_seconds;
            sink_(std::span<const std::byte>(pkt.datagram.data(), pkt.datagram.size()));
            ack_dirty_ = false;
        }
    }

    // Emit standalone ack if needed and no reliable packet was just sent.
    if (ack_dirty_ && rel_cum_ack_ != 0) {
        std::vector<std::byte> buf;
        // Ack-only: seq=0 (we're not sending new data), payload_len=0
        write_header(buf, NetChannel::Unreliable,
                     kFlagAckOnly, 0, 0);
        transmit_datagram(buf);
    }
}

// ===========================================================================
// UdpSocket — POSIX implementation
// (No-op stubs when BF_NO_SOCKETS is defined for CI builds.)
// ===========================================================================

UdpSocket::~UdpSocket() { close(); }

UdpSocket::UdpSocket(UdpSocket&& o) noexcept : fd_(o.fd_) { o.fd_ = -1; }

UdpSocket& UdpSocket::operator=(UdpSocket&& o) noexcept {
    if (this != &o) { close(); fd_ = o.fd_; o.fd_ = -1; }
    return *this;
}

void UdpSocket::close() {
#ifndef BF_NO_SOCKETS
    if (fd_ >= 0) { ::close(fd_); fd_ = -1; }
#else
    fd_ = -1;
#endif
}

bool UdpSocket::bind(std::uint16_t port) {
#ifndef BF_NO_SOCKETS
    fd_ = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (fd_ < 0) return false;
    int flags = ::fcntl(fd_, F_GETFL, 0);
    if (flags < 0 || ::fcntl(fd_, F_SETFL, flags | O_NONBLOCK) < 0) {
        close(); return false;
    }
    sockaddr_in addr{};
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port        = htons(port);
    if (::bind(fd_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        close(); return false;
    }
    return true;
#else
    (void)port;
    return false;
#endif
}

bool UdpSocket::sendto(std::string_view address, std::uint16_t port,
                       std::span<const std::byte> data) {
#ifndef BF_NO_SOCKETS
    if (fd_ < 0) return false;
    sockaddr_in dest{};
    dest.sin_family = AF_INET;
    dest.sin_port   = htons(port);
    // Convert address
    std::string addr_str(address);
    if (::inet_pton(AF_INET, addr_str.c_str(), &dest.sin_addr) != 1) return false;
    ssize_t sent = ::sendto(fd_,
                            data.data(), data.size_bytes(), 0,
                            reinterpret_cast<sockaddr*>(&dest), sizeof(dest));
    return sent == static_cast<ssize_t>(data.size_bytes());
#else
    (void)address; (void)port; (void)data;
    return false;
#endif
}

std::size_t UdpSocket::recvfrom(std::span<std::byte> buf,
                                 char out_addr[64], std::uint16_t& out_port) {
#ifndef BF_NO_SOCKETS
    if (fd_ < 0) return 0;
    sockaddr_in src{};
    socklen_t slen = sizeof(src);
    ssize_t n = ::recvfrom(fd_,
                            buf.data(), buf.size_bytes(), 0,
                            reinterpret_cast<sockaddr*>(&src), &slen);
    if (n <= 0) return 0;
    if (::inet_ntop(AF_INET, &src.sin_addr, out_addr, 64) == nullptr) {
        out_addr[0] = '\0';
    }
    out_port = ntohs(src.sin_port);
    return static_cast<std::size_t>(n);
#else
    (void)buf; (void)out_addr; (void)out_port;
    return 0;
#endif
}

// ===========================================================================
// UdpTransport — implementation
// ===========================================================================

bool UdpTransport::start_host(std::uint16_t port)
{
    is_host_ = true;
    host_port_ = port;
    return socket_.bind(port);
}

bool UdpTransport::connect(std::string_view host, std::uint16_t port)
{
    is_host_  = false;
    host_addr_ = std::string(host);
    host_port_ = port;
    // Create a peer entry for the server (peer_id=1 by convention for client).
    find_or_create_peer(host_addr_, host_port_);
    return true;  // Non-blocking; actual handshake happens via poll().
}

void UdpTransport::stop()
{
    socket_.close();
    peers_.clear();
    peer_by_id_.clear();
    next_peer_id_ = 1;
}

void UdpTransport::send(NetChannel ch, std::span<const std::byte> payload,
                        std::uint32_t peer)
{
    if (peer == 0) {
        // Broadcast to all peers.
        for (auto& p : peers_) {
            p->endpoint.send(ch, payload);
        }
    } else {
        auto it = peer_by_id_.find(peer);
        if (it != peer_by_id_.end()) {
            it->second->endpoint.send(ch, payload);
        }
    }
}

void UdpTransport::poll()
{
    // Advance monotonic clock (very coarse: ~16 ms per poll call as a stand-in
    // for the actual wall-clock; real apps should pass wall-clock here).
    clock_ += 0.016;

    // Update all endpoints (resends + standalone acks).
    for (auto& p : peers_) {
        p->endpoint.update(clock_);
    }

    // Drain the socket.
    std::vector<std::byte> buf(65536);
    char addr[64];
    std::uint16_t port{};
    while (true) {
        std::size_t n = socket_.recvfrom(std::span<std::byte>(buf.data(), buf.size()),
                                          addr, port);
        if (n == 0) break;
        auto* peer_info = find_or_create_peer(std::string(addr), port);
        peer_info->endpoint.on_datagram(
            std::span<const std::byte>(buf.data(), n));
    }
}

UdpTransport::PeerInfo* UdpTransport::find_or_create_peer(const std::string& addr,
                                                            std::uint16_t port)
{
    // Key: addr:port string
    for (auto& p : peers_) {
        if (p->address == addr && p->port == port) return p.get();
    }

    std::uint32_t id = next_peer_id_++;
    std::string   saddr = addr;
    std::uint16_t sport = port;
    std::uint32_t sid   = id;

    // The sink for this peer: capture address/port and send via socket_.
    DatagramSink sink = [this, saddr, sport](std::span<const std::byte> dg) {
        socket_.sendto(saddr, sport, dg);
    };

    auto info = std::make_unique<PeerInfo>(addr, port, id, std::move(sink));

    // Wire up receive callback.
    if (recv_cb_) {
        auto* raw = info.get();
        auto cb   = recv_cb_;
        raw->endpoint.set_receiver(
            [cb, sid](NetChannel ch, std::span<const std::byte> payload) {
                cb(sid, ch, payload);
            });
    }

    PeerInfo* raw = info.get();
    peer_by_id_[id] = raw;
    peers_.push_back(std::move(info));
    return raw;
}

} // namespace bf
