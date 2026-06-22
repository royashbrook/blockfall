// ============================================================================
// Blockfall — co-op session / replication (Track H, engine/include/.../session.hpp)
// Server-authoritative. The HOST owns the authoritative World; clients run the
// same deterministic worldgen (same seed) and only EDITS + player positions are
// networked — terrain regenerates locally, so no chunk streaming over the wire.
//
// Consistency: every block edit funnels through the host. The host applies
// edits in arrival order and broadcasts the authoritative result to ALL
// clients, so two clients editing the same block converge to the host's order.
// Clients predict their own edits locally and reconcile to the host broadcast.
//
// Transport-agnostic: NetSession emits payloads through a `sender` callback and
// is fed delivered payloads via on_payload(). The app wires these to the UDP
// ReliableEndpoints (net.hpp); tests wire them to an in-memory lossy link.
// ============================================================================
#pragma once
#include "blockcore/world.hpp"
#include "blockcore_interfaces.hpp"

#include <cstdint>
#include <cstring>
#include <functional>
#include <unordered_map>
#include <vector>
#include <span>

namespace bf {

enum class NetRole { Host, Client };

// Application packet types (first 2 bytes of every payload).
enum class PktType : std::uint16_t {
    Hello = 1, Welcome = 2, BlockEdit = 3, PlayerPos = 4, Snapshot = 5
};

// ---- little-endian payload writer/reader ----------------------------------
struct PktWriter {
    std::vector<std::byte> buf;
    template <class T> void put(const T& v) {
        const auto* p = reinterpret_cast<const std::byte*>(&v);
        buf.insert(buf.end(), p, p + sizeof(T));
    }
    void put_type(PktType t) { put(std::uint16_t(t)); }
    std::span<const std::byte> span() const { return {buf.data(), buf.size()}; }
};
struct PktReader {
    const std::byte* p; const std::byte* end;
    explicit PktReader(std::span<const std::byte> s) : p(s.data()), end(s.data() + s.size()) {}
    template <class T> bool get(T& v) {
        if (p + sizeof(T) > end) return false;
        std::memcpy(&v, p, sizeof(T)); p += sizeof(T); return true;
    }
    PktType type() { std::uint16_t t = 0; get(t); return PktType(t); }
};

class NetSession {
public:
    using Sender = std::function<void(std::uint16_t peer, NetChannel, std::span<const std::byte>)>;

    NetSession(World& world, NetRole role) : world_(world), role_(role) {
        // Local edits replicate: host broadcasts to all; client sends to host.
        world_.set_edit_callback([this](IVec3 w, BlockId b) { on_local_edit(w, b); });
    }

    void set_sender(Sender s) { sender_ = std::move(s); }

    // A peer became reachable (host: a new client id; client: the host, id 0).
    void on_peer_join(std::uint16_t peer) {
        peers_.push_back(peer);
        if (role_ == NetRole::Client) send_to(peer, NetChannel::ReliableOrdered, hello());
    }
    void on_peer_leave(std::uint16_t peer) {
        peers_.erase(std::remove(peers_.begin(), peers_.end(), peer), peers_.end());
        remote_.erase(peer);
        rebuild_avatars();
    }

    void on_payload(std::uint16_t peer, NetChannel /*ch*/, std::span<const std::byte> data) {
        // Learn peers from their traffic (the UDP transport discovers them on
        // arrival; this keeps the broadcast set in sync without an explicit join).
        if (std::find(peers_.begin(), peers_.end(), peer) == peers_.end()) peers_.push_back(peer);
        PktReader r(data);
        switch (r.type()) {
            case PktType::Hello: {
                // Host welcomes the client with the seed (+ mode) so it can gen
                // the identical world locally.
                if (role_ == NetRole::Host) send_to(peer, NetChannel::ReliableOrdered, welcome());
                break;
            }
            case PktType::Welcome: {
                std::uint64_t seed = 0; std::uint8_t mode = 0;
                if (!r.get(seed) || !r.get(mode)) break;   // ignore truncated packets
                world_.set_mode(bf_game_mode(mode));
                world_.init_world(seed);          // deterministic: matches host
                joined_ = true;
                break;
            }
            case PktType::BlockEdit: {
                IVec3 w{}; BlockId b = 0;
                if (!r.get(w) || !r.get(b)) break; // truncated: don't corrupt the world
                world_.apply_remote_edit(w, b);   // authoritative apply, no re-fire
                if (role_ == NetRole::Host) broadcast_edit(w, b);  // relay to everyone
                break;
            }
            case PktType::PlayerPos: {
                // Zero-init + checked reads: a short packet must never leave NaN/garbage
                // here — these floats become entity vertex positions on the GPU.
                float x{}, y{}, z{}, yaw{};
                if (!r.get(x) || !r.get(y) || !r.get(z) || !r.get(yaw)) break;
                remote_[peer] = {x, y, z, yaw};
                rebuild_avatars();
                break;
            }
            default: break;
        }
    }

    void update(double dt) {
        snap_timer_ += dt;
        if (snap_timer_ < 0.05) return;          // 20 Hz position updates
        snap_timer_ = 0.0;
        float x, y, z, yaw; world_.get_player(x, y, z, yaw);
        PktWriter w; w.put_type(PktType::PlayerPos); w.put(x); w.put(y); w.put(z); w.put(yaw);
        for (auto p : peers_) send_to(p, NetChannel::Unreliable, w.span());
    }

    bool joined() const { return joined_; }
    unsigned peer_count() const { return unsigned(peers_.size()); }

private:
    struct RemotePlayer { float x, y, z, yaw; };

    void on_local_edit(IVec3 w, BlockId b) {
        if (role_ == NetRole::Host) broadcast_edit(w, b);
        else for (auto p : peers_) send_block_edit(p, w, b);   // client -> host
    }
    void broadcast_edit(IVec3 w, BlockId b) { for (auto p : peers_) send_block_edit(p, w, b); }
    void send_block_edit(std::uint16_t peer, IVec3 w, BlockId b) {
        PktWriter pw; pw.put_type(PktType::BlockEdit); pw.put(w); pw.put(b);
        send_to(peer, NetChannel::ReliableOrdered, pw.span());
    }
    std::span<const std::byte> hello() {
        hello_.buf.clear(); hello_.put_type(PktType::Hello); return hello_.span();
    }
    std::span<const std::byte> welcome() {
        welcome_.buf.clear(); welcome_.put_type(PktType::Welcome);
        welcome_.put(world_.world_seed()); welcome_.put(std::uint8_t(world_.mode()));
        return welcome_.span();
    }
    void send_to(std::uint16_t peer, NetChannel ch, std::span<const std::byte> d) {
        if (sender_) sender_(peer, ch, d);
    }
    void rebuild_avatars() {
        std::vector<bf_entity_draw> av;
        for (auto& [peer, rp] : remote_) {
            bf_entity_draw e{};
            e.position = bf_vec3{rp.x, rp.y - 1.0f, rp.z};
            e.yaw = rp.yaw; e.color = bf_vec3{0.95f, 0.75f, 0.85f};
            // kind 100 = REMOTE PLAYER: the renderer draws a humanoid avatar and the
            // HUD compass (#13) points to it (distinct from animals/villagers).
            e.scale = 1.2f; e.kind = 100; e.sat = 1.0f;
            av.push_back(e);
        }
        world_.set_remote_avatars(av);
    }

    World&  world_;
    NetRole role_;
    Sender  sender_;
    std::vector<std::uint16_t> peers_;
    std::unordered_map<std::uint16_t, RemotePlayer> remote_;
    PktWriter hello_, welcome_;
    double  snap_timer_{0};
    bool    joined_{false};
};

} // namespace bf
