// ============================================================================
// Blockfall — Track H: reliable-UDP networking layer
// (engine/include/blockcore/net.hpp)
//
// Two layers:
//   (A) ReliableEndpoint — reliability state machine over an abstract datagram
//       link.  Does NOT own a socket; wired via DatagramSink.  Fully testable
//       with in-memory lossy links (no OS sockets required in CI).
//   (B) UdpSocket — thin POSIX non-blocking UDP wrapper (compile-time only;
//       not exercised in the unit test so CI sandbox cannot block it).
//   (C) UdpTransport — glues UdpSocket + per-peer ReliableEndpoints together
//       and implements bf::INetTransport for the app layer.
//
// Wire format (formats.md §3, all little-endian):
//   char magic[4]  = 'B','F','N','W'
//   uint16 version = 1
//   uint8  channel
//   uint8  flags   (bit0 = ack-only / no payload)
//   uint32 seq
//   uint32 ack        (highest seq received from remote)
//   uint32 ack_bits   (bits 0..31 => ack-1..ack-32 received)
//   uint16 peer_id
//   uint16 payload_len
//   ... payload ...
// ============================================================================
#pragma once

#include "blockcore_interfaces.hpp"

#include <array>
#include <cstdint>
#include <cstring>
#include <deque>
#include <functional>
#include <map>
#include <span>
#include <unordered_map>
#include <vector>

// POSIX headers needed by UdpSocket — only included when not in a pure-logic
// test build.  Tests define BF_NO_SOCKETS to skip the socket-specific code
// paths (the class is still declared and compiles; only the member bodies that
// call POSIX syscalls need a socket descriptor).
#ifndef BF_NO_SOCKETS
#  include <arpa/inet.h>
#  include <netinet/in.h>
#  include <sys/socket.h>
#  include <unistd.h>
#endif

namespace bf {

// ---------------------------------------------------------------------------
// Header layout (packed, little-endian)
// Total: 4+2+1+1+4+4+4+2+2 = 24 bytes
// ---------------------------------------------------------------------------
inline constexpr std::array<char, 4> kNetMagic  = {'B','F','N','W'};
inline constexpr std::uint16_t       kNetVersion = 1;
inline constexpr std::size_t         kNetHeaderSize = 24;
inline constexpr std::uint8_t        kFlagAckOnly   = 0x01u;  // piggyback/standalone ack

// ---------------------------------------------------------------------------
// DatagramSink — the one seam between reliability and transport.
// ReliableEndpoint calls this to emit a fully-formed datagram (header+payload).
// Tests wire it to an in-memory lossy link; the app wires it to sendto().
// ---------------------------------------------------------------------------
using DatagramSink = std::function<void(std::span<const std::byte>)>;

// ---------------------------------------------------------------------------
// (A) ReliableEndpoint
//
// Reliability scheme:
//   - Each endpoint maintains an outgoing sequence counter (next_seq_out_).
//   - Reliable channels (ReliableOrdered, ReliableUnordered) keep a copy of
//     every sent packet in unacked_ until the remote acks it.
//   - The BFNW header carries: seq (outgoing), ack (highest incoming seq seen),
//     ack_bits (bitmask of 32 preceding seqs relative to ack).
//   - On receipt the sender purges all acked entries from unacked_.
//   - Resend fires when now_seconds - sent_at > kResendTimeoutSec (100 ms).
//   - ReliableOrdered: out-of-order arrivals are held in reorder_buf_ and
//     released when all preceding seqs have been delivered.
//   - ReliableUnordered: deliver on first receipt; dedup via received_seqs_ set.
//   - Unreliable: newest-wins — drop if seq <= last delivered seq.
//   - Piggyback acks are sent on every datagram.  If no outgoing data is ready
//     but acks need sending, update() emits a header-only (ack-only) packet.
//
// No throwing across the public boundary.
// No per-packet heap churn: unacked packets are stored once (std::vector<byte>
// copy on send) and not copied again on resend.
// ---------------------------------------------------------------------------
class ReliableEndpoint {
public:
    static constexpr double kResendTimeoutSec = 0.100;   // 100 ms

    // DatagramSink is called synchronously from send() / update() to emit a
    // fully-formed BFNW datagram.
    explicit ReliableEndpoint(DatagramSink sink, std::uint16_t peer_id = 0)
        : sink_(std::move(sink)), peer_id_(peer_id) {}

    // ---- application API --------------------------------------------------

    // Queue and immediately transmit a datagram on the given channel.
    void send(NetChannel ch, std::span<const std::byte> payload);

    // Feed a received datagram (raw BFNW bytes) into the endpoint.
    void on_datagram(std::span<const std::byte> bytes);

    // Called once per frame / tick.  Resends timed-out reliable packets and
    // emits standalone acks if needed.
    void update(double now_seconds);

    // Callback invoked for each DELIVERED application payload.
    // For ReliableOrdered: in-order delivery.
    // For ReliableUnordered: as-received (first receipt only).
    // For Unreliable: newest-wins (monotonically advancing seq).
    void set_receiver(std::function<void(NetChannel, std::span<const std::byte>)> cb) {
        receiver_ = std::move(cb);
    }

    // ---- diagnostics -------------------------------------------------------
    std::size_t unacked_count() const { return unacked_.size(); }

private:
    // ---- header helpers ----------------------------------------------------
    struct Header {
        // Parsed fields
        std::uint8_t  channel{};
        std::uint8_t  flags{};
        std::uint32_t seq{};
        std::uint32_t ack{};
        std::uint32_t ack_bits{};
        std::uint16_t peer_id{};
        std::uint16_t payload_len{};
    };

    static bool parse_header(std::span<const std::byte> data, Header& out);
    void        write_header(std::vector<std::byte>& buf, NetChannel ch,
                             std::uint8_t flags, std::uint32_t seq,
                             std::uint16_t payload_len) const;
    void        transmit_datagram(std::vector<std::byte>& buf);

    // ---- reliable helpers --------------------------------------------------
    void process_acks(std::uint32_t remote_ack, std::uint32_t remote_ack_bits);
    void try_deliver_ordered(std::uint32_t seq, std::span<const std::byte> payload);
    bool already_received(std::uint32_t seq) const;
    void mark_received(std::uint32_t seq);

    // ---- outgoing unacked packet -------------------------------------------
    struct UnackedPacket {
        std::uint32_t          seq{};
        NetChannel             channel{NetChannel::ReliableOrdered};
        double                 sent_at{0.0};
        std::vector<std::byte> datagram;  // full BFNW bytes (header + payload)
    };

    // ---- members -----------------------------------------------------------
    DatagramSink   sink_;
    std::uint16_t  peer_id_;

    // Outgoing state. Reliable channels share next_seq_out_ (kept contiguous so
    // ReliableOrdered never stalls); Unreliable has its OWN seq space so its
    // (lossy, never-acked) packets don't punch permanent gaps in the reliable
    // sequence and deadlock ordered delivery.
    std::uint32_t next_seq_out_{1};      // reliable channels
    std::uint32_t next_unrel_seq_out_{1};// unreliable channel
    std::vector<UnackedPacket> unacked_;

    // Incoming state (per-channel)
    // ReliableOrdered
    std::uint32_t next_expected_ord_{1};       // next seq we want to deliver
    std::map<std::uint32_t, std::vector<std::byte>> reorder_buf_; // seq -> payload

    // ReliableUnordered — dedup set.
    // Tracks seq numbers of packets already delivered so resends are ignored.
    // Pruned when entries fall more than kUnordDedupWindow behind the current max.
    static constexpr std::uint32_t kUnordDedupWindow = 512;
    std::uint32_t received_unord_max_{0};
    std::unordered_map<std::uint32_t, bool> received_unord_set_;

    // Unreliable
    std::uint32_t last_unreliable_seq_{0};     // newest seq delivered so far

    // Ack tracking.
    //
    // We maintain TWO ack views:
    //   rel_cum_ack_  — cumulative: the highest seq N such that all of
    //                   1..N have been received on reliable channels.
    //                   This is what we place in the BFNW header `ack` field
    //                   for reliable-channel senders so their unacked entries
    //                   never fall out of the 32-bit ack_bits window.
    //   rel_cum_bits_ — ack_bits for up to 32 seqs above rel_cum_ack_ that
    //                   have arrived out of order (same encoding as the header).
    //
    // For the receiver to compute rel_cum_ack_ it needs a set of all seqs seen
    // on reliable channels — we reuse the reorder_buf_ (ReliableOrdered) and
    // received_unord_set_ (ReliableUnordered).  A separate received_rel_set_
    // covers seqs of both reliable channels.
    std::uint32_t rel_cum_ack_{0};    // cumulative reliable ack (in header `ack`)
    std::uint32_t rel_cum_bits_{0};   // ack_bits for seqs above rel_cum_ack_
    std::unordered_map<std::uint32_t, bool> received_rel_set_; // all reliably received seqs

    // Callback
    std::function<void(NetChannel, std::span<const std::byte>)> receiver_;

    // Dirty-ack flag: set when we've received new reliable data but haven't
    // piggybacked an ack yet (triggers standalone ack in update()).
    bool ack_dirty_{false};
    double last_update_{0.0};
};

// ---------------------------------------------------------------------------
// (B) UdpSocket — thin POSIX non-blocking UDP wrapper
// Not exercised by CI unit test; compile-time only in CI (BF_NO_SOCKETS).
// ---------------------------------------------------------------------------
class UdpSocket {
public:
    UdpSocket() = default;
    ~UdpSocket();

    UdpSocket(const UdpSocket&)            = delete;
    UdpSocket& operator=(const UdpSocket&) = delete;
    UdpSocket(UdpSocket&&) noexcept;
    UdpSocket& operator=(UdpSocket&&) noexcept;

    // Bind to a local port (host mode).
    bool bind(std::uint16_t port);

    // Open an unbound non-blocking socket (client mode): the OS assigns an
    // ephemeral local port on the first sendto. Without this the client never
    // had a socket at all and LAN join silently did nothing.
    bool open_unbound();

    // Send datagram to address:port.
    bool sendto(std::string_view address, std::uint16_t port,
                std::span<const std::byte> data);

    // Non-blocking receive.  Returns number of bytes received (0 = none pending).
    // Fills out_addr (dotted-decimal) and out_port on success.
    std::size_t recvfrom(std::span<std::byte> buf,
                         char out_addr[64], std::uint16_t& out_port);

    bool is_open() const { return fd_ >= 0; }
    void close();

private:
    int fd_{-1};
};

// ---------------------------------------------------------------------------
// (C) UdpTransport — glues UdpSocket + per-peer ReliableEndpoints.
//
// Implements bf::INetTransport.  Because INetTransport has no receive callback
// hook, UdpTransport adds its own:
//
//   void set_receive_callback(
//       std::function<void(std::uint32_t peer_id, NetChannel,
//                          std::span<const std::byte> payload)>)
//
// The app must call this before poll() to receive incoming messages.
// ---------------------------------------------------------------------------
class UdpTransport final : public INetTransport {
public:
    // Set the application-level receive hook.  Called for each delivered
    // payload (delivery semantics per channel; see ReliableEndpoint).
    // NOTE: INetTransport has no such hook; this is an addition to the
    // transport layer.  See formats.md §3 and the architecture note in net.hpp.
    void set_receive_callback(
        std::function<void(std::uint32_t peer_id, NetChannel ch,
                           std::span<const std::byte> payload)> cb) {
        recv_cb_ = std::move(cb);
    }

    // bf::INetTransport
    bool     start_host(std::uint16_t port) override;
    bool     connect(std::string_view host, std::uint16_t port) override;
    void     stop() override;
    void     send(NetChannel ch, std::span<const std::byte> payload,
                  std::uint32_t peer = 0) override;
    void     poll() override;
    unsigned peer_count() const override {
        return static_cast<unsigned>(peers_.size());
    }

private:
    struct PeerInfo {
        std::string        address;
        std::uint16_t      port{};
        std::uint32_t      id{};
        ReliableEndpoint   endpoint;

        PeerInfo(std::string addr, std::uint16_t p, std::uint32_t peer_id,
                 DatagramSink sink)
            : address(std::move(addr)), port(p), id(peer_id),
              endpoint(std::move(sink), static_cast<std::uint16_t>(peer_id)) {}
    };

    UdpSocket  socket_;
    double     clock_{0.0};  // simple monotonic clock advanced per poll()

    std::unordered_map<std::uint32_t, PeerInfo*> peer_by_id_;
    std::vector<std::unique_ptr<PeerInfo>>        peers_;
    std::uint32_t                                 next_peer_id_{1};

    bool is_host_{false};
    std::string host_addr_;
    std::uint16_t host_port_{};

    std::function<void(std::uint32_t, NetChannel, std::span<const std::byte>)> recv_cb_;

    PeerInfo* find_or_create_peer(const std::string& addr, std::uint16_t port);
};

} // namespace bf
