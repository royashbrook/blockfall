//! End-to-end co-op smoke test over REAL localhost UDP sockets.
//!
//! Spins a host + a client as two separate transport/session pairs bound to
//! 127.0.0.1, drives the handshake, places a block on the host, and asserts the
//! client receives and applies it (and vice versa). This exercises the actual
//! `std::net::UdpSocket` path the LAN app uses, not just the in-memory link.
//!
//! Mirrors the FFI wiring (wire_net + bf_frame_begin pump) but in one process,
//! using two ports on the loopback interface. If the sandbox blocks UDP this
//! test will fail to bind and is the signal that LAN must be verified on-device.

use bfcore::abi::*;
use bfcore::content::ContentRegistry;
use bfcore::net::{NetChannel, UdpTransport};
use bfcore::session::{NetRole, NetSession};
use bfcore::world::{self, World};

use std::cell::RefCell;
use std::os::raw::c_void;
use std::rc::Rc;

const CONTENT: &str = "/Users/roy/gh/blockfall/content";

extern "C" fn alloc_fn(_user: *mut c_void, bytes: u32) -> bf_gpu_buffer {
    let n = if bytes != 0 { bytes } else { 16 } as usize;
    let mut v = vec![0u8; n];
    let p = v.as_mut_ptr();
    std::mem::forget(v);
    bf_gpu_buffer {
        handle: p as u64,
        contents: p as *mut c_void,
        bytes,
    }
}
extern "C" fn free_fn(_user: *mut c_void, _handle: bf_handle) {}
fn allocator() -> bf_gpu_allocator {
    bf_gpu_allocator {
        user: std::ptr::null_mut(),
        alloc: Some(alloc_fn),
        free_: Some(free_fn),
    }
}

/// One networked endpoint: a World + transport + session + the two bridge queues
/// (mirrors the Engine's net_inbox/net_outbox wiring in ffi.rs).
struct Node<'c> {
    world: World<'c>,
    transport: UdpTransport,
    session: NetSession,
    inbox: Rc<RefCell<Vec<(u16, NetChannel, Vec<u8>)>>>,
    outbox: Rc<RefCell<Vec<(u16, NetChannel, Vec<u8>)>>>,
}

impl<'c> Node<'c> {
    fn new(content: &'c ContentRegistry, role: NetRole) -> Node<'c> {
        let mut world = World::new(Some(bfcore::worldgen::TerrainGen::new()));
        world.set_content(content);
        world.set_allocator(allocator());
        world.set_mode(bf_game_mode::BF_MODE_CREATIVE);

        let mut transport = UdpTransport::new();
        let inbox: Rc<RefCell<Vec<(u16, NetChannel, Vec<u8>)>>> = Rc::new(RefCell::new(Vec::new()));
        let ib = inbox.clone();
        transport.set_receive_callback(Box::new(move |peer: u32, ch, payload: &[u8]| {
            ib.borrow_mut().push((peer as u16, ch, payload.to_vec()));
        }));

        let mut session = NetSession::new(role);
        let outbox: Rc<RefCell<Vec<(u16, NetChannel, Vec<u8>)>>> =
            Rc::new(RefCell::new(Vec::new()));
        let ob = outbox.clone();
        session.set_sender(Box::new(move |peer: u16, ch, payload: &[u8]| {
            ob.borrow_mut().push((peer, ch, payload.to_vec()));
        }));
        session.install_edit_callback(&mut world);

        Node {
            world,
            transport,
            session,
            inbox,
            outbox,
        }
    }

    /// One frame: poll transport, deliver to session, update session, flush out.
    /// Mirrors bf_frame_begin's net pump.
    fn pump(&mut self, dt: f64) {
        self.transport.poll();
        let inbound: Vec<(u16, NetChannel, Vec<u8>)> =
            std::mem::take(&mut *self.inbox.borrow_mut());
        for (peer, ch, payload) in inbound {
            self.session.on_payload(peer, ch, &payload, &mut self.world);
        }
        self.session.update(dt, &mut self.world);
        let outbound: Vec<(u16, NetChannel, Vec<u8>)> =
            std::mem::take(&mut *self.outbox.borrow_mut());
        for (peer, ch, payload) in outbound {
            self.transport.send(ch, &payload, peer as u32);
        }
    }
}

#[test]
fn coop_smoke_localhost() {
    let mut content = ContentRegistry::new();
    if !content.load(CONTENT) {
        panic!("content load failed at {CONTENT}");
    }

    let mut host = Node::new(&content, NetRole::Host);
    let mut client = Node::new(&content, NetRole::Client);

    host.world.init_world(4242); // host authoritative seed

    // Bind the host. Try a small range of ports in case one is busy.
    let mut bound_port = 0u16;
    for port in 39000u16..39050 {
        if host.transport.start_host(port) {
            bound_port = port;
            break;
        }
    }
    assert!(
        bound_port != 0,
        "host failed to bind any localhost UDP port (sandbox may block UDP -- \
         verify LAN co-op on-device)"
    );

    // Client connects to the host and sends HELLO.
    assert!(
        client.transport.connect("127.0.0.1", bound_port),
        "client failed to open a UDP socket (sandbox may block UDP)"
    );
    client.session.on_peer_join(1); // host is peer 1
                                    // Flush the queued HELLO right away (as bf_net_client_connect does).
    let outbound: Vec<(u16, NetChannel, Vec<u8>)> =
        std::mem::take(&mut *client.outbox.borrow_mut());
    for (peer, ch, payload) in outbound {
        client.transport.send(ch, &payload, peer as u32);
    }

    // Pump both nodes until the client joins (gets WELCOME(seed)) or we time out.
    let dt = 0.05;
    let mut joined = false;
    for _ in 0..400 {
        host.pump(dt);
        client.pump(dt);
        std::thread::sleep(std::time::Duration::from_millis(2));
        if client.session.joined() {
            joined = true;
            break;
        }
    }
    assert!(
        joined,
        "client never received WELCOME / joined over localhost"
    );
    assert_eq!(
        client.world.world_seed(),
        4242,
        "client generated the host's world from the synced seed"
    );

    // Host places a block; client must receive + apply it.
    let glow: u16 = world::GLOW;
    host.world.debug_edit(70, 60, 70, glow);
    let mut got_host_edit = false;
    for _ in 0..400 {
        host.pump(dt);
        client.pump(dt);
        std::thread::sleep(std::time::Duration::from_millis(2));
        if client.world.debug_block_at(70, 60, 70) == glow {
            got_host_edit = true;
            break;
        }
    }
    assert!(
        got_host_edit,
        "client did not receive the host's block edit over localhost"
    );

    // Client places a block; host must receive + apply it (round-trip the other
    // direction, with the host relaying it back to all clients).
    let stone: u16 = world::STONE;
    client.world.debug_edit(72, 60, 70, stone);
    let mut got_client_edit = false;
    for _ in 0..400 {
        host.pump(dt);
        client.pump(dt);
        std::thread::sleep(std::time::Duration::from_millis(2));
        if host.world.debug_block_at(72, 60, 70) == stone {
            got_client_edit = true;
            break;
        }
    }
    assert!(
        got_client_edit,
        "host did not receive the client's block edit over localhost"
    );

    // Peer counts reflect the live link.
    assert!(
        host.transport.peer_count() >= 1,
        "host sees the client peer"
    );
    assert!(
        client.transport.peer_count() >= 1,
        "client sees the host peer"
    );
}
