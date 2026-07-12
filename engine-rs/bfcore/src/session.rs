//! bfcore: co-op session / replication (Track H, Rust port of session.hpp).
//!
//! Server-authoritative. The HOST owns the authoritative World; clients run the
//! same deterministic worldgen (same seed) so only EDITS and player positions
//! are networked. Terrain regenerates locally, so there is no chunk streaming
//! over the wire.
//!
//! Consistency: every block edit funnels through the host, which applies edits
//! in arrival order and broadcasts the authoritative result to ALL clients, so
//! two clients editing the same block converge to the host's order.
//!
//! Transport-agnostic: `NetSession` emits payloads through a `sender` callback
//! and is fed delivered payloads via `on_payload()`. The app wires these to the
//! UDP `ReliableEndpoint`s (net.rs); tests wire them to an in-memory lossy link.
//!
//! ## Wire format (matches session.hpp byte-for-byte, all little-endian)
//!
//! Every payload starts with a uint16 packet type:
//!   Hello    = 1  : (no body)
//!   Welcome  = 2  : uint64 seed, uint8 mode
//!   BlockEdit= 3  : IVec3 (3x int32), BlockId (uint16)        -> 12 + 2 bytes
//!   PlayerPos= 4  : float x, y, z, yaw                        -> 16 bytes
//!   Snapshot = 5  : (reserved; not currently emitted)
//!
//! ## Borrow model
//!
//! Unlike the C++ (which stores a `World&`), this `NetSession` does NOT hold a
//! reference to the World. Methods that touch the world take `&mut World` as a
//! parameter. This sidesteps the self-referential-struct problem entirely with
//! zero `unsafe`: the FFI layer owns both the World and the session and passes
//! `&mut world` into each session call.
//!
//! Local edits still need to replicate. The C++ installs a World edit callback
//! in the session ctor; here the session owns a shared `local_edits` queue and
//! `install_edit_callback()` wires a boxed World closure that pushes edits into
//! it. `drain_local_edits(&mut world)` flushes the queue and replicates each one
//! (host broadcasts; client sends to host). The FFI layer calls it each frame.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use crate::abi::{
    bf_entity_draw, bf_entity_role_action, bf_game_mode, bf_player_appearance, bf_vec3,
};
use crate::net::NetChannel;
use crate::types::{BlockId, IVec3};
use crate::world::World;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum NetRole {
    Host,
    Client,
}

/// Application packet types (first 2 bytes of every payload). Matches `PktType`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(u16)]
enum PktType {
    Hello = 1,
    Welcome = 2,
    BlockEdit = 3,
    PlayerPos = 4,
    #[allow(dead_code)]
    Snapshot = 5,
    PlayerState = 6,
}

impl PktType {
    fn from_u16(v: u16) -> Option<PktType> {
        match v {
            1 => Some(PktType::Hello),
            2 => Some(PktType::Welcome),
            3 => Some(PktType::BlockEdit),
            4 => Some(PktType::PlayerPos),
            5 => Some(PktType::Snapshot),
            6 => Some(PktType::PlayerState),
            _ => None,
        }
    }
}

// ---------------------------------------------------------------------------
// little-endian payload writer/reader (match PktWriter/PktReader).
// The C++ `put(T)` writes the raw struct bytes; on the little-endian targets we
// support (arm64/x86_64) this equals the explicit LE encoding below, so the
// wire bytes are identical.
// ---------------------------------------------------------------------------
struct PktWriter {
    buf: Vec<u8>,
}
impl PktWriter {
    fn new() -> PktWriter {
        PktWriter { buf: Vec::new() }
    }
    fn put_type(&mut self, t: PktType) {
        self.put_u16(t as u16);
    }
    fn put_u16(&mut self, v: u16) {
        self.buf.extend_from_slice(&v.to_le_bytes());
    }
    fn put_u64(&mut self, v: u64) {
        self.buf.extend_from_slice(&v.to_le_bytes());
    }
    fn put_u8(&mut self, v: u8) {
        self.buf.push(v);
    }
    fn put_f32(&mut self, v: f32) {
        self.buf.extend_from_slice(&v.to_le_bytes());
    }
    fn put_ivec3(&mut self, v: IVec3) {
        self.buf.extend_from_slice(&v.x.to_le_bytes());
        self.buf.extend_from_slice(&v.y.to_le_bytes());
        self.buf.extend_from_slice(&v.z.to_le_bytes());
    }
}

struct PktReader<'a> {
    p: &'a [u8],
    pos: usize,
}
impl<'a> PktReader<'a> {
    fn new(s: &'a [u8]) -> PktReader<'a> {
        PktReader { p: s, pos: 0 }
    }
    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        if self.pos + n > self.p.len() {
            return None;
        }
        let s = &self.p[self.pos..self.pos + n];
        self.pos += n;
        Some(s)
    }
    fn get_u16(&mut self) -> Option<u16> {
        let s = self.take(2)?;
        Some(u16::from_le_bytes([s[0], s[1]]))
    }
    fn get_u64(&mut self) -> Option<u64> {
        let s = self.take(8)?;
        Some(u64::from_le_bytes(s.try_into().unwrap()))
    }
    fn get_u8(&mut self) -> Option<u8> {
        Some(self.take(1)?[0])
    }
    fn get_f32(&mut self) -> Option<f32> {
        let s = self.take(4)?;
        Some(f32::from_le_bytes(s.try_into().unwrap()))
    }
    fn get_ivec3(&mut self) -> Option<IVec3> {
        let x = i32::from_le_bytes(self.take(4)?.try_into().unwrap());
        let y = i32::from_le_bytes(self.take(4)?.try_into().unwrap());
        let z = i32::from_le_bytes(self.take(4)?.try_into().unwrap());
        Some(IVec3 { x, y, z })
    }
    /// Read the leading packet type. Mirrors `PktReader::type()` (returns 0 on a
    /// truncated read; from_u16(0) is None so the switch hits the default arm).
    fn pkt_type(&mut self) -> Option<PktType> {
        let t = self.get_u16().unwrap_or(0);
        PktType::from_u16(t)
    }
}

/// Sender: emits a payload toward a peer on a channel.
pub type Sender = Box<dyn FnMut(u16, NetChannel, &[u8])>;

/// Shared queue of local edits captured by the World edit callback.
pub type LocalEditQueue = Rc<RefCell<Vec<(IVec3, BlockId)>>>;

#[derive(Clone, Copy)]
struct RemotePlayer {
    x: f32,
    y: f32,
    z: f32,
    yaw: f32,
    appearance: bf_player_appearance,
    moving: bool,
    action: u32,
    action_progress: f32,
}

/// Server-authoritative co-op session. See module docs for the borrow model.
pub struct NetSession {
    role: NetRole,
    sender: Option<Sender>,
    peers: Vec<u16>,
    joined_peers: HashSet<u16>,
    remote: HashMap<u16, RemotePlayer>,
    local_edits: LocalEditQueue,
    snap_timer: f64,
    joined: bool,
    local_appearance: bf_player_appearance,
}

impl NetSession {
    pub fn new(role: NetRole) -> NetSession {
        NetSession {
            role,
            sender: None,
            peers: Vec::new(),
            joined_peers: HashSet::new(),
            remote: HashMap::new(),
            local_edits: Rc::new(RefCell::new(Vec::new())),
            snap_timer: 0.0,
            joined: false,
            local_appearance: bf_player_appearance::default(),
        }
    }

    pub fn set_local_appearance(&mut self, appearance: bf_player_appearance) {
        self.local_appearance = appearance;
    }

    /// Install the World edit callback that funnels local edits into our queue.
    /// Mirrors the C++ `world_.set_edit_callback(...)` in the NetSession ctor.
    /// Must be called once after construction (the FFI layer does this).
    pub fn install_edit_callback(&self, world: &mut World) {
        let q = self.local_edits.clone();
        world.set_edit_callback(Box::new(move |w: IVec3, b: BlockId| {
            q.borrow_mut().push((w, b));
        }));
    }

    pub fn set_sender(&mut self, s: Sender) {
        self.sender = Some(s);
    }

    pub fn joined(&self) -> bool {
        self.joined
    }

    pub fn peer_count(&self) -> u32 {
        self.peers.len() as u32
    }

    /// A peer became reachable (host: a new client id; client: the host, id 0).
    /// On the client this sends HELLO to the host.
    pub fn on_peer_join(&mut self, peer: u16) {
        self.peers.push(peer);
        if self.role == NetRole::Client {
            self.send_to(peer, NetChannel::ReliableOrdered, &Self::hello());
        }
    }

    #[allow(dead_code)]
    pub fn on_peer_leave(&mut self, peer: u16, world: &mut World) {
        self.peers.retain(|&p| p != peer);
        self.joined_peers.remove(&peer);
        self.remote.remove(&peer);
        self.rebuild_avatars(world);
    }

    /// Feed a delivered payload from `peer` into the session.
    pub fn on_payload(&mut self, peer: u16, _ch: NetChannel, data: &[u8], world: &mut World) {
        // Learn peers from their traffic (the UDP transport discovers them on
        // arrival; this keeps the broadcast set in sync without an explicit join).
        if !self.peers.contains(&peer) {
            self.peers.push(peer);
        }
        let mut r = PktReader::new(data);
        match r.pkt_type() {
            Some(PktType::Hello) => {
                // Host welcomes the client with the seed (+ mode) so it can gen
                // the identical world locally.
                if self.role == NetRole::Host {
                    self.joined_peers.insert(peer);
                    let w = Self::welcome(world);
                    self.send_to(peer, NetChannel::ReliableOrdered, &w);
                }
            }
            Some(PktType::Welcome) => {
                if self.role != NetRole::Client {
                    return;
                }
                let seed = match r.get_u64() {
                    Some(s) => s,
                    None => return, // ignore truncated packets
                };
                let mode = match r.get_u8() {
                    Some(m) => m,
                    None => return,
                };
                world.set_mode(Self::game_mode_from_u8(mode));
                world.init_world(seed); // deterministic: matches host
                self.joined = true;
            }
            Some(PktType::BlockEdit) => {
                if self.role == NetRole::Host {
                    if !self.joined_peers.contains(&peer) {
                        return;
                    }
                } else if !self.joined {
                    return;
                }
                let w = match r.get_ivec3() {
                    Some(v) => v,
                    None => return, // truncated: don't corrupt the world
                };
                let b = match r.get_u16() {
                    Some(v) => v,
                    None => return,
                };
                world.apply_remote_edit(w, b); // authoritative apply, no re-fire
                if self.role == NetRole::Host {
                    self.broadcast_edit(w, b); // relay to everyone
                }
            }
            Some(PktType::PlayerPos) => {
                // Zero-init + checked reads: a short packet must never leave
                // NaN/garbage here (these floats become GPU vertex positions).
                let x = match r.get_f32() {
                    Some(v) => v,
                    None => return,
                };
                let y = match r.get_f32() {
                    Some(v) => v,
                    None => return,
                };
                let z = match r.get_f32() {
                    Some(v) => v,
                    None => return,
                };
                let yaw = match r.get_f32() {
                    Some(v) => v,
                    None => return,
                };
                self.remote.insert(peer, RemotePlayer {
                    x, y, z, yaw, appearance: bf_player_appearance::default(),
                    moving: false, action: 0, action_progress: 0.0,
                });
                self.rebuild_avatars(world);
            }
            Some(PktType::PlayerState) => {
                if self.role == NetRole::Host && !self.joined_peers.contains(&peer) {
                    return;
                }
                if self.role == NetRole::Client && !self.joined {
                    return;
                }
                let claimed_origin = match r.get_u16() { Some(v) => v, None => return };
                let x = match r.get_f32() { Some(v) => v, None => return };
                let y = match r.get_f32() { Some(v) => v, None => return };
                let z = match r.get_f32() { Some(v) => v, None => return };
                let yaw = match r.get_f32() { Some(v) => v, None => return };
                let appearance = match Self::read_appearance(&mut r) { Some(v) => v, None => return };
                // Appended animation fields are optional so v29 peers remain
                // compatible: older packets simply render an idle avatar.
                let moving = r.get_u8().unwrap_or(0) != 0;
                let action = r.get_u8().unwrap_or(0) as u32;
                let action_progress = r.get_f32().unwrap_or(0.0).clamp(0.0, 1.0);
                // Clients cannot spoof another peer id. The host assigns the
                // transport id, then relays that canonical state to all others.
                let origin = if self.role == NetRole::Host { peer } else { claimed_origin };
                self.remote.insert(origin, RemotePlayer {
                    x, y, z, yaw, appearance, moving, action, action_progress,
                });
                if self.role == NetRole::Host {
                    let relay = Self::player_state(
                        origin, x, y, z, yaw, appearance, moving, action, action_progress,
                    );
                    let peers = self.peers.clone();
                    for target in peers {
                        if target != peer && self.joined_peers.contains(&target) {
                            self.send_to(target, NetChannel::Unreliable, &relay);
                        }
                    }
                }
                self.rebuild_avatars(world);
            }
            _ => {}
        }
    }

    /// Per-frame tick. Flushes pending local edits then, at 20 Hz, sends a
    /// player-position snapshot to every peer. `dt` is in seconds.
    pub fn update(&mut self, dt: f64, world: &mut World) {
        // Replicate any local edits captured since the last call. The C++ fires
        // these synchronously from set_block_internal; here they queue and we
        // drain them each tick (still in edit order).
        self.drain_local_edits(world);

        self.snap_timer += dt;
        if self.snap_timer < 0.05 {
            return; // 20 Hz position updates
        }
        self.snap_timer = 0.0;
        let (x, y, z, yaw) = world.get_player();
        let (moving, action, action_progress) = world.player_animation_state();
        let w = Self::player_state(
            0, x, y, z, yaw, self.local_appearance, moving, action, action_progress,
        );
        let peers = self.peers.clone();
        for p in peers {
            self.send_to(p, NetChannel::Unreliable, &w);
        }
    }

    /// Flush the local-edit queue, replicating each edit. Public so the FFI
    /// layer (and tests) can force a drain right after a local edit, matching
    /// the C++ synchronous fire-on-edit behaviour.
    pub fn drain_local_edits(&mut self, _world: &mut World) {
        let edits: Vec<(IVec3, BlockId)> = {
            let mut q = self.local_edits.borrow_mut();
            std::mem::take(&mut *q)
        };
        for (w, b) in edits {
            self.on_local_edit(w, b);
        }
    }

    // ---- internals --------------------------------------------------------

    fn on_local_edit(&mut self, w: IVec3, b: BlockId) {
        if self.role == NetRole::Host {
            self.broadcast_edit(w, b);
        } else {
            // client -> host
            let peers = self.peers.clone();
            for p in peers {
                self.send_block_edit(p, w, b);
            }
        }
    }

    fn broadcast_edit(&mut self, w: IVec3, b: BlockId) {
        let peers = self.peers.clone();
        for p in peers {
            self.send_block_edit(p, w, b);
        }
    }

    fn send_block_edit(&mut self, peer: u16, w: IVec3, b: BlockId) {
        let mut pw = PktWriter::new();
        pw.put_type(PktType::BlockEdit);
        pw.put_ivec3(w);
        pw.put_u16(b);
        self.send_to(peer, NetChannel::ReliableOrdered, &pw.buf);
    }

    fn hello() -> Vec<u8> {
        let mut w = PktWriter::new();
        w.put_type(PktType::Hello);
        w.buf
    }

    fn welcome(world: &World) -> Vec<u8> {
        let mut w = PktWriter::new();
        w.put_type(PktType::Welcome);
        w.put_u64(world.world_seed());
        w.put_u8(world.mode() as u8);
        w.buf
    }

    fn put_appearance(w: &mut PktWriter, a: bf_player_appearance) {
        for v in [a.skin, a.shirt, a.hair_color, a.hair_style, a.nose,
                  a.mouth, a.eye_style, a.eye_color, a.head_shape, a.body_shape] {
            w.put_u8(v);
        }
    }

    fn read_appearance(r: &mut PktReader<'_>) -> Option<bf_player_appearance> {
        Some(bf_player_appearance {
            skin: r.get_u8()?, shirt: r.get_u8()?, hair_color: r.get_u8()?,
            hair_style: r.get_u8()?, nose: r.get_u8()?, mouth: r.get_u8()?,
            eye_style: r.get_u8()?, eye_color: r.get_u8()?,
            head_shape: r.get_u8()?, body_shape: r.get_u8()?, _reserved: [0; 2],
        })
    }

    #[allow(clippy::too_many_arguments)]
    fn player_state(
        origin: u16,
        x: f32,
        y: f32,
        z: f32,
        yaw: f32,
        appearance: bf_player_appearance,
        moving: bool,
        action: u32,
        action_progress: f32,
    ) -> Vec<u8> {
        let mut w = PktWriter::new();
        w.put_type(PktType::PlayerState);
        w.put_u16(origin);
        w.put_f32(x); w.put_f32(y); w.put_f32(z); w.put_f32(yaw);
        Self::put_appearance(&mut w, appearance);
        w.put_u8(u8::from(moving));
        w.put_u8(action.min(u8::MAX as u32) as u8);
        w.put_f32(action_progress.clamp(0.0, 1.0));
        w.buf
    }

    fn send_to(&mut self, peer: u16, ch: NetChannel, d: &[u8]) {
        if let Some(s) = self.sender.as_mut() {
            s(peer, ch, d);
        }
    }

    fn rebuild_avatars(&self, world: &mut World) {
        let mut av: Vec<bf_entity_draw> = Vec::new();
        let mut appearances = Vec::new();
        let mut actions = Vec::new();
        for (&peer_id, rp) in &self.remote {
            av.push(bf_entity_draw {
                position: bf_vec3 {
                    x: rp.x,
                    y: rp.y - 1.0,
                    z: rp.z,
                },
                yaw: rp.yaw,
                color: bf_vec3 {
                    x: 0.95,
                    y: 0.75,
                    z: 0.85,
                },
                // kind 100 = REMOTE PLAYER: the renderer draws a humanoid avatar
                // and the HUD compass points to it (distinct from animals).
                scale: 1.2,
                kind: 100,
                sat: 1.0,
                _pad: u32::from(peer_id).wrapping_add(1),
            });
            appearances.push(rp.appearance);
            actions.push(bf_entity_role_action {
                role: 0,
                action: rp.action,
                progress: rp.action_progress,
                _pad: u32::from(rp.moving),
            });
        }
        world.set_remote_avatars(av, appearances, actions);
    }

    fn game_mode_from_u8(m: u8) -> bf_game_mode {
        match m {
            0 => bf_game_mode::BF_MODE_SURVIVAL,
            _ => bf_game_mode::BF_MODE_CREATIVE,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn edit_packet(w: IVec3, b: BlockId) -> Vec<u8> {
        let mut p = PktWriter::new();
        p.put_type(PktType::BlockEdit);
        p.put_ivec3(w);
        p.put_u16(b);
        p.buf
    }

    fn welcome_packet(seed: u64) -> Vec<u8> {
        let mut p = PktWriter::new();
        p.put_type(PktType::Welcome);
        p.put_u64(seed);
        p.put_u8(bf_game_mode::BF_MODE_CREATIVE as u8);
        p.buf
    }

    fn hello_packet() -> Vec<u8> {
        let mut p = PktWriter::new();
        p.put_type(PktType::Hello);
        p.buf
    }

    #[test]
    fn host_ignores_inbound_welcome() {
        let mut world = World::new(None);
        world.init_world(123);
        let mut session = NetSession::new(NetRole::Host);

        session.on_payload(
            7,
            NetChannel::ReliableOrdered,
            &welcome_packet(999),
            &mut world,
        );

        assert_eq!(world.world_seed(), 123);
        assert!(!session.joined());
    }

    #[test]
    fn host_ignores_block_edit_before_hello() {
        let mut world = World::new(None);
        world.init_world(123);
        let pos = IVec3 { x: 1, y: 1, z: 1 };
        let before = world.debug_block_at(pos.x, pos.y, pos.z);
        let mut session = NetSession::new(NetRole::Host);

        session.on_payload(
            7,
            NetChannel::ReliableOrdered,
            &edit_packet(pos, 42),
            &mut world,
        );

        assert_eq!(world.debug_block_at(pos.x, pos.y, pos.z), before);
    }

    #[test]
    fn player_state_roundtrips_every_appearance_trait() {
        let appearance = bf_player_appearance {
            skin: 9, shirt: 8, hair_color: 7, hair_style: 6, nose: 5,
            mouth: 4, eye_style: 3, eye_color: 2, head_shape: 1,
            body_shape: 9, _reserved: [0; 2],
        };
        let packet = NetSession::player_state(
            42, 1.0, 2.0, 3.0, 4.0, appearance, true, 11, 0.625,
        );
        let mut reader = PktReader::new(&packet);
        assert_eq!(reader.pkt_type(), Some(PktType::PlayerState));
        assert_eq!(reader.get_u16(), Some(42));
        for expected in [1.0, 2.0, 3.0, 4.0] {
            assert_eq!(reader.get_f32(), Some(expected));
        }
        assert_eq!(NetSession::read_appearance(&mut reader), Some(appearance));
        assert_eq!(reader.get_u8(), Some(1));
        assert_eq!(reader.get_u8(), Some(11));
        assert_eq!(reader.get_f32(), Some(0.625));
    }

    #[test]
    fn host_canonicalizes_and_relays_client_appearance() {
        let mut world = World::new(None);
        world.init_world(123);
        let mut session = NetSession::new(NetRole::Host);
        let sent = Rc::new(RefCell::new(Vec::<(u16, Vec<u8>)>::new()));
        let captured = sent.clone();
        session.set_sender(Box::new(move |peer, _, data| {
            captured.borrow_mut().push((peer, data.to_vec()));
        }));
        session.on_payload(7, NetChannel::ReliableOrdered, &hello_packet(), &mut world);
        session.on_payload(8, NetChannel::ReliableOrdered, &hello_packet(), &mut world);
        sent.borrow_mut().clear();

        let appearance = bf_player_appearance {
            skin: 2, shirt: 3, hair_color: 4, hair_style: 5, nose: 6,
            mouth: 7, eye_style: 8, eye_color: 9, head_shape: 1,
            body_shape: 2, _reserved: [0; 2],
        };
        let spoofed = NetSession::player_state(
            999, 10.0, 11.0, 12.0, 1.5, appearance, true, 11, 0.5,
        );
        session.on_payload(7, NetChannel::Unreliable, &spoofed, &mut world);

        assert_eq!(session.remote.get(&7).unwrap().appearance, appearance);
        assert!(session.remote.get(&7).unwrap().moving);
        assert_eq!(session.remote.get(&7).unwrap().action, 11);
        assert!(session.remote.get(&999).is_none());
        let outbound = sent.borrow();
        assert_eq!(outbound.len(), 1);
        assert_eq!(outbound[0].0, 8);
        let mut reader = PktReader::new(&outbound[0].1);
        assert_eq!(reader.pkt_type(), Some(PktType::PlayerState));
        assert_eq!(reader.get_u16(), Some(7));
    }

    #[test]
    fn legacy_player_position_uses_safe_default_appearance() {
        let mut world = World::new(None);
        world.init_world(123);
        let mut session = NetSession::new(NetRole::Host);
        let mut p = PktWriter::new();
        p.put_type(PktType::PlayerPos);
        for v in [1.0, 2.0, 3.0, 4.0] { p.put_f32(v); }
        session.on_payload(7, NetChannel::Unreliable, &p.buf, &mut world);
        assert_eq!(session.remote.get(&7).unwrap().appearance, bf_player_appearance::default());
    }

    #[test]
    fn changed_local_appearance_is_sent_on_next_snapshot() {
        let mut world = World::new(None);
        world.init_world(123);
        let mut session = NetSession::new(NetRole::Client);
        session.peers.push(1);
        let sent = Rc::new(RefCell::new(Vec::<Vec<u8>>::new()));
        let captured = sent.clone();
        session.set_sender(Box::new(move |_, _, data| captured.borrow_mut().push(data.to_vec())));
        let appearance = bf_player_appearance {
            skin: 8, shirt: 7, hair_color: 6, hair_style: 5, nose: 4,
            mouth: 3, eye_style: 2, eye_color: 1, head_shape: 9,
            body_shape: 8, _reserved: [0; 2],
        };
        session.set_local_appearance(appearance);
        session.update(0.05, &mut world);
        let packets = sent.borrow();
        let mut reader = PktReader::new(&packets[0]);
        assert_eq!(reader.pkt_type(), Some(PktType::PlayerState));
        assert_eq!(reader.get_u16(), Some(0));
        for _ in 0..4 { reader.get_f32().unwrap(); }
        assert_eq!(NetSession::read_appearance(&mut reader), Some(appearance));
    }
}
