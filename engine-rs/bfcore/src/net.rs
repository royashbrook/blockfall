//! bfcore: Track H reliable-UDP networking layer (Rust port of net.hpp/net.cpp).
//!
//! Three layers, mirroring the C++ exactly:
//!   (A) `ReliableEndpoint` — reliability state machine over an abstract datagram
//!       link. Does NOT own a socket; wired via a `DatagramSink` closure. Fully
//!       testable with in-memory lossy links (no OS sockets required).
//!   (B) `UdpSocket` — thin non-blocking UDP wrapper over `std::net::UdpSocket`.
//!   (C) `UdpTransport` — glues `UdpSocket` + per-peer `ReliableEndpoint`s and
//!       provides the app-layer send/poll/receive surface.
//!
//! Wire format (formats.md sec 3, all little-endian), 24-byte header:
//!   char   magic[4]  = 'B','F','N','W'
//!   uint16 version   = 1
//!   uint8  channel
//!   uint8  flags     (bit0 = ack-only / no payload)
//!   uint32 seq
//!   uint32 ack       (cumulative reliable ack)
//!   uint32 ack_bits  (bits 0..31 => ack+1..ack+32 received out of order)
//!   uint16 peer_id
//!   uint16 payload_len
//!   ... payload ...
//!
//! The byte layout matches the C++ implementation exactly so a Rust host and a
//! Rust client interoperate over the wire (and ideally a Rust client could talk
//! to a C++ host).

use std::collections::{BTreeMap, HashMap};
use std::net::{SocketAddr, ToSocketAddrs, UdpSocket as StdUdpSocket};

// ---------------------------------------------------------------------------
// Header constants (mirror net.hpp).
// ---------------------------------------------------------------------------
pub const NET_MAGIC: [u8; 4] = [b'B', b'F', b'N', b'W'];
pub const NET_VERSION: u16 = 1;
pub const NET_HEADER_SIZE: usize = 24;
pub const FLAG_ACK_ONLY: u8 = 0x01;

/// Channel selector. Matches `bf::NetChannel` (blockcore_interfaces.hpp).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum NetChannel {
    ReliableOrdered = 0,
    ReliableUnordered = 1,
    Unreliable = 2,
}

impl NetChannel {
    fn from_u8(v: u8) -> Option<NetChannel> {
        match v {
            0 => Some(NetChannel::ReliableOrdered),
            1 => Some(NetChannel::ReliableUnordered),
            2 => Some(NetChannel::Unreliable),
            _ => None,
        }
    }
}

/// A fully-formed datagram sink. `ReliableEndpoint` calls this synchronously from
/// `send()`/`update()` to emit a BFNW datagram (header + payload).
pub type DatagramSink = Box<dyn FnMut(&[u8])>;

/// Callback invoked per delivered application payload.
pub type Receiver = Box<dyn FnMut(NetChannel, &[u8])>;

// ---------------------------------------------------------------------------
// little-endian read/write helpers (match net.cpp).
// ---------------------------------------------------------------------------
#[inline]
fn write_u16_le(p: &mut [u8], v: u16) {
    p[0] = (v & 0xFF) as u8;
    p[1] = ((v >> 8) & 0xFF) as u8;
}
#[inline]
fn write_u32_le(p: &mut [u8], v: u32) {
    p[0] = (v & 0xFF) as u8;
    p[1] = ((v >> 8) & 0xFF) as u8;
    p[2] = ((v >> 16) & 0xFF) as u8;
    p[3] = ((v >> 24) & 0xFF) as u8;
}
#[inline]
fn read_u16_le(p: &[u8]) -> u16 {
    (p[0] as u16) | ((p[1] as u16) << 8)
}
#[inline]
fn read_u32_le(p: &[u8]) -> u32 {
    (p[0] as u32) | ((p[1] as u32) << 8) | ((p[2] as u32) << 16) | ((p[3] as u32) << 24)
}

/// Sequence-number comparison: `a` is "before" `b` in a wrapping sense if the
/// forward unsigned distance a -> b is non-zero and within the half-window.
/// Mirrors net.cpp `seq_before`.
#[inline]
fn seq_before(a: u32, b: u32) -> bool {
    b != a && b.wrapping_sub(a) < 0x8000_0000
}

// ===========================================================================
// (A) ReliableEndpoint
// ===========================================================================

const RESEND_TIMEOUT_SEC: f64 = 0.100; // 100 ms
const UNORD_DEDUP_WINDOW: u32 = 512;
const REORDER_WINDOW: u32 = 4096;
const ACK_WINDOW: u32 = 4096;
const MAX_UNACKED: usize = 8192;

struct ParsedHeader {
    channel: u8,
    flags: u8,
    seq: u32,
    ack: u32,
    ack_bits: u32,
    #[allow(dead_code)]
    peer_id: u16,
    payload_len: u16,
}

struct UnackedPacket {
    seq: u32,
    #[allow(dead_code)]
    channel: NetChannel,
    sent_at: f64,
    datagram: Vec<u8>, // full BFNW bytes (header + payload)
}

/// Reliability state machine for one peer link. See module docs.
pub struct ReliableEndpoint {
    sink: DatagramSink,
    peer_id: u16,

    // Outgoing state. Reliable channels share `next_seq_out`; Unreliable has its
    // own seq space so its lossy never-acked packets do not punch permanent gaps
    // in the reliable sequence and deadlock ordered delivery.
    next_seq_out: u32,
    next_unrel_seq_out: u32,
    unacked: Vec<UnackedPacket>,

    // Incoming: ReliableOrdered.
    next_expected_ord: u32,
    reorder_buf: BTreeMap<u32, Vec<u8>>,

    // Incoming: ReliableUnordered dedup set.
    received_unord_max: u32,
    received_unord_set: HashMap<u32, bool>,

    // Incoming: Unreliable newest-wins.
    last_unreliable_seq: u32,

    // Ack tracking (see net.hpp for the two-view scheme).
    rel_cum_ack: u32,
    rel_cum_bits: u32,
    received_rel_set: HashMap<u32, bool>,

    receiver: Option<Receiver>,

    ack_dirty: bool,
    last_update: f64,
}

impl ReliableEndpoint {
    pub fn new(sink: DatagramSink, peer_id: u16) -> ReliableEndpoint {
        ReliableEndpoint {
            sink,
            peer_id,
            next_seq_out: 1,
            next_unrel_seq_out: 1,
            unacked: Vec::new(),
            next_expected_ord: 1,
            reorder_buf: BTreeMap::new(),
            received_unord_max: 0,
            received_unord_set: HashMap::new(),
            last_unreliable_seq: 0,
            rel_cum_ack: 0,
            rel_cum_bits: 0,
            received_rel_set: HashMap::new(),
            receiver: None,
            ack_dirty: false,
            last_update: 0.0,
        }
    }

    pub fn set_receiver(&mut self, cb: Receiver) {
        self.receiver = Some(cb);
    }

    pub fn unacked_count(&self) -> usize {
        self.unacked.len()
    }

    // ---- header helpers ---------------------------------------------------

    fn parse_header(data: &[u8]) -> Option<ParsedHeader> {
        if data.len() < NET_HEADER_SIZE {
            return None;
        }
        if data[0] != NET_MAGIC[0]
            || data[1] != NET_MAGIC[1]
            || data[2] != NET_MAGIC[2]
            || data[3] != NET_MAGIC[3]
        {
            return None;
        }
        let ver = read_u16_le(&data[4..]);
        if ver != NET_VERSION {
            return None;
        }
        let h = ParsedHeader {
            channel: data[6],
            flags: data[7],
            seq: read_u32_le(&data[8..]),
            ack: read_u32_le(&data[12..]),
            ack_bits: read_u32_le(&data[16..]),
            peer_id: read_u16_le(&data[20..]),
            payload_len: read_u16_le(&data[22..]),
        };
        // Sanity: payload must fit.
        if NET_HEADER_SIZE + h.payload_len as usize > data.len() {
            return None;
        }
        Some(h)
    }

    /// Serialise the BFNW header into `buf` (resizes it to NET_HEADER_SIZE).
    /// Uses the current cumulative-ack state for the ack/ack_bits fields.
    fn write_header(
        &self,
        buf: &mut Vec<u8>,
        ch: NetChannel,
        flags: u8,
        seq: u32,
        payload_len: u16,
    ) {
        buf.clear();
        buf.resize(NET_HEADER_SIZE, 0);
        buf[0] = b'B';
        buf[1] = b'F';
        buf[2] = b'N';
        buf[3] = b'W';
        write_u16_le(&mut buf[4..], NET_VERSION);
        buf[6] = ch as u8;
        buf[7] = flags;
        write_u32_le(&mut buf[8..], seq);
        write_u32_le(&mut buf[12..], self.rel_cum_ack);
        write_u32_le(&mut buf[16..], self.rel_cum_bits);
        write_u16_le(&mut buf[20..], self.peer_id);
        write_u16_le(&mut buf[22..], payload_len);
    }

    fn transmit_datagram(&mut self, buf: &[u8]) {
        (self.sink)(buf);
        self.ack_dirty = false;
    }

    // ---- application API --------------------------------------------------

    /// Build a BFNW datagram, store a copy for reliable channels, transmit.
    pub fn send(&mut self, ch: NetChannel, payload: &[u8]) {
        let seq = if ch == NetChannel::Unreliable {
            let s = self.next_unrel_seq_out;
            self.next_unrel_seq_out = self.next_unrel_seq_out.wrapping_add(1);
            s
        } else {
            let s = self.next_seq_out;
            self.next_seq_out = self.next_seq_out.wrapping_add(1);
            s
        };
        let plen = payload.len().min(0xFFFF) as u16;

        let mut buf: Vec<u8> = Vec::with_capacity(NET_HEADER_SIZE + plen as usize);
        self.write_header(&mut buf, ch, 0, seq, plen);
        buf.extend_from_slice(&payload[..plen as usize]);

        if ch == NetChannel::ReliableOrdered || ch == NetChannel::ReliableUnordered {
            // Bound memory if a peer goes silent: drop the oldest at the cap.
            if self.unacked.len() >= MAX_UNACKED {
                self.unacked.remove(0);
            }
            self.unacked.push(UnackedPacket {
                seq,
                channel: ch,
                sent_at: self.last_update,
                datagram: buf.clone(),
            });
        }

        self.transmit_datagram(&buf);
    }

    // ---- reliable helpers -------------------------------------------------

    /// Remove unacked entries confirmed by the remote.
    /// `remote_ack` is cumulative (all seqs 1..=remote_ack received);
    /// `remote_ack_bits` bit k => seq (remote_ack + k + 1) also received.
    fn process_acks(&mut self, remote_ack: u32, remote_ack_bits: u32) {
        if remote_ack == 0 {
            return;
        }
        let is_acked = |s: u32| -> bool {
            // Cumulative: everything up to and including remote_ack is acked.
            if !seq_before(remote_ack, s) {
                return true; // s <= remote_ack
            }
            let delta = s.wrapping_sub(remote_ack); // s > remote_ack, delta >= 1
            if delta > 32 {
                return false;
            }
            (remote_ack_bits & (1u32 << (delta - 1))) != 0
        };
        self.unacked.retain(|pkt| !is_acked(pkt.seq));
    }

    fn already_received(&self, seq: u32) -> bool {
        if self.received_unord_max != 0 && !seq_before(self.received_unord_max, seq) {
            let delta = self.received_unord_max.wrapping_sub(seq);
            if delta > UNORD_DEDUP_WINDOW {
                return true;
            }
        }
        self.received_unord_set.contains_key(&seq)
    }

    fn mark_received(&mut self, seq: u32) {
        self.received_unord_set.insert(seq, true);
        if self.received_unord_max == 0 || seq_before(self.received_unord_max, seq) {
            self.received_unord_max = seq;
        }
        if self.received_unord_max > UNORD_DEDUP_WINDOW {
            let cutoff = self.received_unord_max - UNORD_DEDUP_WINDOW;
            let max = self.received_unord_max;
            self.received_unord_set.retain(|&k, _| {
                // Keep unless clearly below cutoff in a wrapping-safe sense.
                !(!seq_before(cutoff, k) && k != cutoff && !seq_before(max, k))
            });
        }
    }

    /// Attempt to flush contiguous seqs from the reorder buffer (ordered channel).
    fn try_deliver_ordered(&mut self, seq: u32, payload: &[u8]) {
        if seq < self.next_expected_ord {
            return; // old / duplicate
        }
        if seq - self.next_expected_ord >= REORDER_WINDOW {
            return; // implausibly far ahead
        }
        if !self.reorder_buf.contains_key(&seq) {
            if self.reorder_buf.len() >= REORDER_WINDOW as usize {
                return; // buffer full
            }
            self.reorder_buf.insert(seq, payload.to_vec());
        }
        // Drain contiguous run starting at next_expected_ord.
        loop {
            let want = self.next_expected_ord;
            match self.reorder_buf.remove(&want) {
                Some(data) => {
                    if let Some(rx) = self.receiver.as_mut() {
                        rx(NetChannel::ReliableOrdered, &data);
                    }
                    self.next_expected_ord += 1;
                }
                None => break,
            }
        }
    }

    /// Feed a received raw BFNW datagram into the endpoint.
    pub fn on_datagram(&mut self, bytes: &[u8]) {
        let h = match Self::parse_header(bytes) {
            Some(h) => h,
            None => return,
        };

        // Process acks BEFORE the ack-only early return.
        if h.ack != 0 {
            self.process_acks(h.ack, h.ack_bits);
        }

        // Ack-only datagrams carry no application payload.
        if (h.flags & FLAG_ACK_ONLY) != 0 || h.payload_len == 0 {
            return;
        }
        if h.seq == 0 {
            return;
        }

        let ch = match NetChannel::from_u8(h.channel) {
            Some(c) => c,
            None => return,
        };
        let payload = &bytes[NET_HEADER_SIZE..NET_HEADER_SIZE + h.payload_len as usize];

        // ---- cumulative ack tracking for reliable channels ----------------
        if ch == NetChannel::ReliableOrdered || ch == NetChannel::ReliableUnordered {
            if h.seq > self.rel_cum_ack && h.seq - self.rel_cum_ack >= ACK_WINDOW {
                return; // forged / out of range
            }
            self.received_rel_set.insert(h.seq, true);

            while self.received_rel_set.contains_key(&(self.rel_cum_ack + 1)) {
                self.rel_cum_ack += 1;
                self.rel_cum_bits >>= 1;
            }

            if h.seq > self.rel_cum_ack {
                let delta = h.seq - self.rel_cum_ack;
                if delta <= 32 {
                    self.rel_cum_bits |= 1u32 << (delta - 1);
                }
            }

            if self.rel_cum_ack > 0 {
                // Prune entries at/below the cumulative ack (they are acked). The
                // C++ erases when (!seq_before(cum,k) && k != cum+1); retain keeps
                // the complement.
                let cum = self.rel_cum_ack;
                self.received_rel_set
                    .retain(|&k, _| seq_before(cum, k) || k == cum + 1);
            }

            self.ack_dirty = true;
        }

        // ---- deliver payload ----------------------------------------------
        if self.receiver.is_none() {
            return;
        }
        match ch {
            NetChannel::ReliableOrdered => {
                self.try_deliver_ordered(h.seq, payload);
            }
            NetChannel::ReliableUnordered => {
                if !self.already_received(h.seq) {
                    self.mark_received(h.seq);
                    if let Some(rx) = self.receiver.as_mut() {
                        rx(NetChannel::ReliableUnordered, payload);
                    }
                }
            }
            NetChannel::Unreliable => {
                if self.last_unreliable_seq == 0 || seq_before(self.last_unreliable_seq, h.seq) {
                    self.last_unreliable_seq = h.seq;
                    if let Some(rx) = self.receiver.as_mut() {
                        rx(NetChannel::Unreliable, payload);
                    }
                }
            }
        }
    }

    /// Resend timed-out reliable packets; emit a standalone ack if needed.
    pub fn update(&mut self, now_seconds: f64) {
        self.last_update = now_seconds;

        // Resend timed-out reliable packets. Patch the ack fields first so each
        // resend carries fresh piggyback ack info.
        let cum_ack = self.rel_cum_ack;
        let cum_bits = self.rel_cum_bits;
        let mut resent = false;
        for pkt in self.unacked.iter_mut() {
            if now_seconds - pkt.sent_at >= RESEND_TIMEOUT_SEC {
                if pkt.datagram.len() >= NET_HEADER_SIZE {
                    write_u32_le(&mut pkt.datagram[12..], cum_ack);
                    write_u32_le(&mut pkt.datagram[16..], cum_bits);
                }
                pkt.sent_at = now_seconds;
                (self.sink)(&pkt.datagram);
                resent = true;
            }
        }
        if resent {
            self.ack_dirty = false;
        }

        // Emit a standalone ack if needed and nothing was just resent.
        if self.ack_dirty && self.rel_cum_ack != 0 {
            let mut buf: Vec<u8> = Vec::with_capacity(NET_HEADER_SIZE);
            self.write_header(&mut buf, NetChannel::Unreliable, FLAG_ACK_ONLY, 0, 0);
            self.transmit_datagram(&buf);
        }
    }
}

// ===========================================================================
// (B) UdpSocket — non-blocking UDP wrapper over std::net::UdpSocket.
// ===========================================================================

/// Thin non-blocking UDP wrapper. Mirrors the POSIX `UdpSocket` in net.hpp.
pub struct UdpSocket {
    inner: Option<StdUdpSocket>,
}

impl UdpSocket {
    pub fn new() -> UdpSocket {
        UdpSocket { inner: None }
    }

    /// Bind to a local port (host mode), non-blocking.
    pub fn bind(&mut self, port: u16) -> bool {
        match StdUdpSocket::bind(("0.0.0.0", port)) {
            Ok(s) => {
                if s.set_nonblocking(true).is_err() {
                    return false;
                }
                self.inner = Some(s);
                true
            }
            Err(_) => false,
        }
    }

    /// Open an unbound non-blocking socket (client mode): OS assigns an ephemeral
    /// local port on the first send. Bind to port 0 to get one immediately.
    pub fn open_unbound(&mut self) -> bool {
        match StdUdpSocket::bind(("0.0.0.0", 0)) {
            Ok(s) => {
                if s.set_nonblocking(true).is_err() {
                    return false;
                }
                self.inner = Some(s);
                true
            }
            Err(_) => false,
        }
    }

    /// Send a datagram to address:port. Returns true on full send.
    pub fn send_to(&self, address: &str, port: u16, data: &[u8]) -> bool {
        let sock = match &self.inner {
            Some(s) => s,
            None => return false,
        };
        let addr: SocketAddr = match (address, port).to_socket_addrs() {
            Ok(mut it) => match it.next() {
                Some(a) => a,
                None => return false,
            },
            Err(_) => return false,
        };
        matches!(sock.send_to(data, addr), Ok(n) if n == data.len())
    }

    /// Non-blocking receive. Returns (bytes, source-addr, source-port) or None.
    pub fn recv_from(&self, buf: &mut [u8]) -> Option<(usize, String, u16)> {
        let sock = self.inner.as_ref()?;
        match sock.recv_from(buf) {
            Ok((n, src)) if n > 0 => Some((n, src.ip().to_string(), src.port())),
            _ => None,
        }
    }

    pub fn is_open(&self) -> bool {
        self.inner.is_some()
    }

    pub fn close(&mut self) {
        self.inner = None;
    }
}

impl Default for UdpSocket {
    fn default() -> Self {
        UdpSocket::new()
    }
}

// ===========================================================================
// (C) UdpTransport — glues UdpSocket + per-peer ReliableEndpoints.
// ===========================================================================

/// Receive hook: called per delivered payload with (peer_id, channel, payload).
pub type ReceiveCallback = Box<dyn FnMut(u32, NetChannel, &[u8])>;

/// Queued outgoing datagram: (dest_addr, dest_port, bytes).
type OutboxItem = (String, u16, Vec<u8>);
/// Queued delivered payload: (peer_id, channel, bytes).
type InboxItem = (u32, NetChannel, Vec<u8>);
type SharedQueue<T> = std::rc::Rc<std::cell::RefCell<Vec<T>>>;

struct PeerInfo {
    address: String,
    port: u16,
    id: u32,
    endpoint: ReliableEndpoint,
}

/// The app-layer transport. Owns the socket and per-peer reliability endpoints.
///
/// Threading: single-threaded, pumped from `poll()` on the engine thread (the
/// C++ runs poll on its E-core net thread, but the Rust app drives it from
/// `bf_frame_begin`, matching engine_stub.cpp). No locks needed.
///
/// The per-peer datagram sink needs to call back into the socket. Rather than
/// share ownership of the socket (Rc/RefCell of the socket), each endpoint's
/// sink writes into a shared outbox `Vec`, and `flush_outbox()` drains it
/// through the socket. Likewise each endpoint's receiver pushes into a shared
/// inbox that `drain_inbox()` feeds to the app callback. This keeps the borrow
/// model simple and safe with zero `unsafe`.
pub struct UdpTransport {
    socket: UdpSocket,
    clock: f64,

    peers: Vec<PeerInfo>,
    next_peer_id: u32,

    is_host: bool,
    host_addr: String,
    host_port: u16,

    recv_cb: Option<ReceiveCallback>,

    // Shared outbox: endpoint sinks push here; flush_outbox drains via the socket.
    outbox: SharedQueue<OutboxItem>,
    // Shared inbox: filled by endpoint receivers, drained into recv_cb after
    // pumping (avoids borrow conflicts between the receiver and the callback).
    inbox: SharedQueue<InboxItem>,
}

impl UdpTransport {
    pub fn new() -> UdpTransport {
        UdpTransport {
            socket: UdpSocket::new(),
            clock: 0.0,
            peers: Vec::new(),
            next_peer_id: 1,
            is_host: false,
            host_addr: String::new(),
            host_port: 0,
            recv_cb: None,
            outbox: std::rc::Rc::new(std::cell::RefCell::new(Vec::new())),
            inbox: std::rc::Rc::new(std::cell::RefCell::new(Vec::new())),
        }
    }

    pub fn set_receive_callback(&mut self, cb: ReceiveCallback) {
        self.recv_cb = Some(cb);
    }

    pub fn is_host(&self) -> bool {
        self.is_host
    }

    pub fn start_host(&mut self, port: u16) -> bool {
        self.is_host = true;
        self.host_port = port;
        self.socket.bind(port)
    }

    pub fn connect(&mut self, host: &str, port: u16) -> bool {
        self.is_host = false;
        self.host_addr = host.to_string();
        self.host_port = port;
        if !self.socket.open_unbound() {
            return false;
        }
        // Create the server peer entry (peer_id 1 by convention).
        self.find_or_create_peer(host, port);
        true
    }

    pub fn stop(&mut self) {
        self.socket.close();
        self.peers.clear();
        self.next_peer_id = 1;
        self.outbox.borrow_mut().clear();
        self.inbox.borrow_mut().clear();
    }

    pub fn peer_count(&self) -> u32 {
        self.peers.len() as u32
    }

    /// Send a payload on a channel. `peer == 0` broadcasts to all peers.
    pub fn send(&mut self, ch: NetChannel, payload: &[u8], peer: u32) {
        if peer == 0 {
            for p in self.peers.iter_mut() {
                p.endpoint.send(ch, payload);
            }
        } else if let Some(p) = self.peers.iter_mut().find(|p| p.id == peer) {
            p.endpoint.send(ch, payload);
        }
        self.flush_outbox();
    }

    /// Pump the socket: advance the clock, run endpoint updates (resends +
    /// standalone acks), then drain received datagrams.
    pub fn poll(&mut self) {
        // Advance the monotonic clock (~16 ms per poll, like the C++ stand-in).
        self.clock += 0.016;

        let now = self.clock;
        for p in self.peers.iter_mut() {
            p.endpoint.update(now);
        }
        self.flush_outbox();

        // Drain the socket.
        let mut buf = vec![0u8; 65536];
        while let Some((n, addr, port)) = self.socket.recv_from(&mut buf) {
            let idx = self.find_or_create_peer_idx(&addr, port);
            let data = buf[..n].to_vec();
            self.peers[idx].endpoint.on_datagram(&data);
        }
        self.flush_outbox();
        self.drain_inbox();
    }

    // ---- internals --------------------------------------------------------

    /// Drain queued datagrams out through the real socket.
    fn flush_outbox(&mut self) {
        let drained: Vec<(String, u16, Vec<u8>)> = {
            let mut ob = self.outbox.borrow_mut();
            std::mem::take(&mut *ob)
        };
        for (addr, port, dg) in drained {
            self.socket.send_to(&addr, port, &dg);
        }
    }

    /// Deliver queued payloads to the app receive callback.
    fn drain_inbox(&mut self) {
        let drained: Vec<(u32, NetChannel, Vec<u8>)> = {
            let mut ib = self.inbox.borrow_mut();
            std::mem::take(&mut *ib)
        };
        if let Some(cb) = self.recv_cb.as_mut() {
            for (peer, ch, payload) in drained {
                cb(peer, ch, &payload);
            }
        }
    }

    fn find_or_create_peer_idx(&mut self, addr: &str, port: u16) -> usize {
        if let Some(i) = self
            .peers
            .iter()
            .position(|p| p.address == addr && p.port == port)
        {
            return i;
        }
        self.create_peer(addr.to_string(), port);
        self.peers.len() - 1
    }

    fn find_or_create_peer(&mut self, addr: &str, port: u16) -> u32 {
        let idx = self.find_or_create_peer_idx(addr, port);
        self.peers[idx].id
    }

    fn create_peer(&mut self, addr: String, port: u16) {
        let id = self.next_peer_id;
        self.next_peer_id += 1;

        // Sink: push fully-formed datagrams into the shared outbox.
        let outbox = self.outbox.clone();
        let saddr = addr.clone();
        let sport = port;
        let sink: DatagramSink = Box::new(move |dg: &[u8]| {
            outbox
                .borrow_mut()
                .push((saddr.clone(), sport, dg.to_vec()));
        });

        let mut endpoint = ReliableEndpoint::new(sink, id as u16);

        // Receiver: push delivered payloads into the shared inbox tagged with id.
        let inbox = self.inbox.clone();
        let pid = id;
        endpoint.set_receiver(Box::new(move |ch: NetChannel, payload: &[u8]| {
            inbox.borrow_mut().push((pid, ch, payload.to_vec()));
        }));

        self.peers.push(PeerInfo {
            address: addr,
            port,
            id,
            endpoint,
        });
    }
}

impl Default for UdpTransport {
    fn default() -> Self {
        UdpTransport::new()
    }
}
