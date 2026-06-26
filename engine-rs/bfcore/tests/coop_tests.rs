//! Co-op consistency test, ported 1:1 from tests/unit/test_coop.cpp.
//!
//! Host + 2 clients, each with its own World, wired through lossy in-memory
//! reliable-UDP links. Proves: clients join and gen the same world from the
//! seed; a client's edit reaches everyone; and two clients editing the SAME
//! block converge to one authoritative value, even at 30% loss.

use bfcore::abi::*;
use bfcore::content::ContentRegistry;
use bfcore::net::{NetChannel, ReliableEndpoint};
use bfcore::session::{NetRole, NetSession};
use bfcore::types::IVec3;
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
extern "C" fn free_fn(_user: *mut c_void, _handle: bf_handle) {
    // Small per-test leak (the C++ test frees exactly; harmless in a test bin).
}
fn allocator() -> bf_gpu_allocator {
    bf_gpu_allocator {
        user: std::ptr::null_mut(),
        alloc: Some(alloc_fn),
        free_: Some(free_fn),
    }
}

// Deterministic PRNG (same xorshift as net_tests; eventual convergence is what
// matters, not bit-identical mt19937 draws).
struct Rng {
    state: u64,
}
impl Rng {
    fn new(seed: u64) -> Rng {
        Rng { state: seed | 1 }
    }
    fn next_u64(&mut self) -> u64 {
        let mut x = self.state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.state = x;
        x
    }
    fn unit(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }
}

#[test]
fn coop_join_replicate_converge() {
    // GLOW/STONE constants (world.rs).
    let glow: u16 = world::GLOW;
    let stone: u16 = world::STONE;

    let mut content = ContentRegistry::new();
    assert!(content.load(CONTENT), "content");

    // Three independent worlds.
    let mut host = World::new(Some(bfcore::worldgen::TerrainGen::new()));
    let mut c1 = World::new(Some(bfcore::worldgen::TerrainGen::new()));
    let mut c2 = World::new(Some(bfcore::worldgen::TerrainGen::new()));
    // All three worlds share an immutable borrow of `content`, which is declared
    // first and so outlives them. No unsafe needed (shared &-borrows).
    host.set_content(&content);
    c1.set_content(&content);
    c2.set_content(&content);
    host.set_allocator(allocator());
    c1.set_allocator(allocator());
    c2.set_allocator(allocator());
    host.set_mode(bf_game_mode::BF_MODE_CREATIVE);
    host.init_world(777); // host authoritative

    let mut hs = NetSession::new(NetRole::Host);
    let mut cs1 = NetSession::new(NetRole::Client);
    let mut cs2 = NetSession::new(NetRole::Client);
    hs.install_edit_callback(&mut host);
    cs1.install_edit_callback(&mut c1);
    cs2.install_edit_callback(&mut c2);

    // ---- lossy in-memory links between 4 endpoints ----
    // eps: 0=host<->c1 (host side), 1=c1 side, 2=host<->c2 (host side), 3=c2 side
    // Endpoint sinks push outgoing datagrams into a shared queue tagged with the
    // *destination* endpoint index (matching the C++ link(dst) closures), with
    // deterministic 30% loss applied at enqueue time (mirrors the C++ drop).
    let loss = 0.30;
    let rng = Rc::new(RefCell::new(Rng::new(12345)));
    // Queue of (dest_ep_index, datagram) to deliver on the next pump.
    let wire: Rc<RefCell<Vec<(usize, Vec<u8>)>>> = Rc::new(RefCell::new(Vec::new()));

    let make_sink = |dst: usize| -> Box<dyn FnMut(&[u8])> {
        let wire = wire.clone();
        let rng = rng.clone();
        Box::new(move |d: &[u8]| {
            if loss > 0.0 && rng.borrow_mut().unit() < loss {
                return; // drop
            }
            wire.borrow_mut().push((dst, d.to_vec()));
        })
    };

    let mut eps: Vec<ReliableEndpoint> = vec![
        ReliableEndpoint::new(make_sink(1), 0),
        ReliableEndpoint::new(make_sink(0), 1),
        ReliableEndpoint::new(make_sink(3), 0),
        ReliableEndpoint::new(make_sink(2), 1),
    ];

    // Receivers push delivered payloads into a shared inbox tagged with which
    // session should handle them and the peer id (mirrors the C++ receivers).
    // session: 0=hs(peer 1), 1=cs1(peer 0), 2=hs(peer 2), 3=cs2(peer 0)
    let inbox: Rc<RefCell<Vec<(usize, u16, NetChannel, Vec<u8>)>>> =
        Rc::new(RefCell::new(Vec::new()));
    {
        let ib = inbox.clone();
        eps[0].set_receiver(Box::new(move |ch, d: &[u8]| {
            ib.borrow_mut().push((0, 1, ch, d.to_vec()));
        }));
    }
    {
        let ib = inbox.clone();
        eps[1].set_receiver(Box::new(move |ch, d: &[u8]| {
            ib.borrow_mut().push((1, 0, ch, d.to_vec()));
        }));
    }
    {
        let ib = inbox.clone();
        eps[2].set_receiver(Box::new(move |ch, d: &[u8]| {
            ib.borrow_mut().push((2, 2, ch, d.to_vec()));
        }));
    }
    {
        let ib = inbox.clone();
        eps[3].set_receiver(Box::new(move |ch, d: &[u8]| {
            ib.borrow_mut().push((3, 0, ch, d.to_vec()));
        }));
    }

    // Session senders push (dest_ep_index, ch, payload) into a shared outbox.
    // hs routes by peer: peer 1 -> eps[0], peer 2 -> eps[2].
    // cs1 -> eps[1]; cs2 -> eps[3] (peer arg ignored, single link).
    let outbox: Rc<RefCell<Vec<(usize, NetChannel, Vec<u8>)>>> = Rc::new(RefCell::new(Vec::new()));
    {
        let ob = outbox.clone();
        hs.set_sender(Box::new(move |peer: u16, ch, d: &[u8]| {
            let ep = if peer == 1 { 0 } else { 2 };
            ob.borrow_mut().push((ep, ch, d.to_vec()));
        }));
    }
    {
        let ob = outbox.clone();
        cs1.set_sender(Box::new(move |_peer: u16, ch, d: &[u8]| {
            ob.borrow_mut().push((1, ch, d.to_vec()));
        }));
    }
    {
        let ob = outbox.clone();
        cs2.set_sender(Box::new(move |_peer: u16, ch, d: &[u8]| {
            ob.borrow_mut().push((3, ch, d.to_vec()));
        }));
    }

    // Flush queued session sends into the endpoints.
    let flush_outbox =
        |eps: &mut [ReliableEndpoint], outbox: &Rc<RefCell<Vec<(usize, NetChannel, Vec<u8>)>>>| {
            let drained: Vec<(usize, NetChannel, Vec<u8>)> =
                std::mem::take(&mut *outbox.borrow_mut());
            for (ep, ch, d) in drained {
                eps[ep].send(ch, &d);
            }
        };

    // Deliver wire datagrams into their destination endpoints.
    let deliver_wire = |eps: &mut [ReliableEndpoint], wire: &Rc<RefCell<Vec<(usize, Vec<u8>)>>>| {
        let drained: Vec<(usize, Vec<u8>)> = std::mem::take(&mut *wire.borrow_mut());
        for (dst, dg) in drained {
            eps[dst].on_datagram(&dg);
        }
    };

    // Deliver inbox payloads into their sessions.
    let deliver_inbox = |hs: &mut NetSession,
                         cs1: &mut NetSession,
                         cs2: &mut NetSession,
                         host: &mut World,
                         c1: &mut World,
                         c2: &mut World,
                         inbox: &Rc<RefCell<Vec<(usize, u16, NetChannel, Vec<u8>)>>>| {
        let drained: Vec<(usize, u16, NetChannel, Vec<u8>)> =
            std::mem::take(&mut *inbox.borrow_mut());
        for (sess, peer, ch, d) in drained {
            match sess {
                0 => hs.on_payload(peer, ch, &d, host),
                1 => cs1.on_payload(peer, ch, &d, c1),
                2 => hs.on_payload(peer, ch, &d, host),
                3 => cs2.on_payload(peer, ch, &d, c2),
                _ => {}
            }
        }
    };

    let mut clk = 0.0;
    // One pump round mirrors the C++ pump: endpoint updates, then session
    // updates, interleaved with wire/inbox/outbox draining so messages flow.
    let mut pump = |rounds: i32,
                    eps: &mut Vec<ReliableEndpoint>,
                    hs: &mut NetSession,
                    cs1: &mut NetSession,
                    cs2: &mut NetSession,
                    host: &mut World,
                    c1: &mut World,
                    c2: &mut World| {
        for _ in 0..rounds {
            clk += 0.05;
            // Deliver datagrams already on the wire, then to sessions.
            deliver_wire(eps, &wire);
            deliver_inbox(hs, cs1, cs2, host, c1, c2, &inbox);
            // Endpoint updates (resends + standalone acks) -> wire.
            for e in eps.iter_mut() {
                e.update(clk);
            }
            // Session updates (drain local edits + 20 Hz snapshots) -> outbox.
            hs.update(0.05, host);
            cs1.update(0.05, c1);
            cs2.update(0.05, c2);
            flush_outbox(eps, &outbox);
            // Deliver again so this round's sends/acks propagate promptly.
            deliver_wire(eps, &wire);
            deliver_inbox(hs, cs1, cs2, host, c1, c2, &inbox);
        }
    };

    hs.on_peer_join(1);
    hs.on_peer_join(2);
    cs1.on_peer_join(0);
    cs2.on_peer_join(0); // clients send HELLO
    flush_outbox(&mut eps, &outbox); // push the HELLOs onto the wire

    pump(
        40, &mut eps, &mut hs, &mut cs1, &mut cs2, &mut host, &mut c1, &mut c2,
    );
    assert!(cs1.joined() && cs2.joined(), "both clients joined and got the seed");
    assert_eq!(c1.world_seed(), 777, "client 1 gens the host's world");
    assert_eq!(c2.world_seed(), 777, "client 2 gens the host's world");

    // ---- a client edit reaches everyone ----
    let p = IVec3 { x: 50, y: 60, z: 50 }; // air above terrain in all worlds
    c1.debug_edit(p.x, p.y, p.z, glow);
    pump(
        40, &mut eps, &mut hs, &mut cs1, &mut cs2, &mut host, &mut c1, &mut c2,
    );
    assert_eq!(
        host.debug_block_at(p.x, p.y, p.z),
        glow,
        "host got the client's edit"
    );
    assert_eq!(
        c2.debug_block_at(p.x, p.y, p.z),
        glow,
        "other client got the edit"
    );

    // ---- two clients edit the SAME block: must converge ----
    let q = IVec3 { x: 52, y: 60, z: 50 };
    c1.debug_edit(q.x, q.y, q.z, glow);
    c2.debug_edit(q.x, q.y, q.z, stone);
    pump(
        80, &mut eps, &mut hs, &mut cs1, &mut cs2, &mut host, &mut c1, &mut c2,
    );
    let hb = host.debug_block_at(q.x, q.y, q.z);
    let b1 = c1.debug_block_at(q.x, q.y, q.z);
    let b2 = c2.debug_block_at(q.x, q.y, q.z);
    assert_ne!(hb, 0, "contested block resolved to a value");
    assert_eq!(hb, b1, "client 1 converged to host's value");
    assert_eq!(hb, b2, "client 2 converged to host's value");
}
