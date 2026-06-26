//! Reliability tests for bfcore::net::ReliableEndpoint, ported 1:1 from the C++
//! tests/unit/test_net.cpp. In-memory lossy links (deterministic PRNG), no real
//! sockets. Same scenarios, same assertions.

use bfcore::net::{NetChannel, ReliableEndpoint};
use std::cell::RefCell;
use std::rc::Rc;

// ---------------------------------------------------------------------------
// Deterministic PRNG matching std::mt19937's role: we only need a reproducible
// stream of doubles in [0,1). A simple xorshift gives stable, seedable output;
// the C++ tests just need *some* deterministic loss pattern, not bit-identical
// mt19937 draws (they assert eventual convergence, not specific drop indices).
// ---------------------------------------------------------------------------
struct Rng {
    state: u64,
}
impl Rng {
    fn new(seed: u64) -> Rng {
        Rng {
            state: seed | 1, // avoid all-zero state
        }
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
        // 53-bit mantissa worth of randomness mapped to [0,1).
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }
}

// ---------------------------------------------------------------------------
// In-memory lossy link: buffers queued datagrams; on deliver() feeds each to the
// destination endpoint after optionally dropping or delaying one round.
// ---------------------------------------------------------------------------
struct LossyLink {
    rng: Rng,
    drop_rate: f64,
    reorder_rate: f64,
    pending: Vec<Vec<u8>>,
}
impl LossyLink {
    fn new(seed: u64, drop_rate: f64, reorder_rate: f64) -> LossyLink {
        LossyLink {
            rng: Rng::new(seed),
            drop_rate,
            reorder_rate,
            pending: Vec::new(),
        }
    }
    fn set_lossless(&mut self) {
        self.drop_rate = 0.0;
        self.reorder_rate = 0.0;
    }
    /// Deliver: returns datagrams that should reach the destination this round.
    /// Dropped datagrams vanish; reordered ones are held for a later round.
    fn deliver(&mut self) -> Vec<Vec<u8>> {
        let batch = std::mem::take(&mut self.pending);
        let mut out = Vec::new();
        for dg in batch {
            if self.rng.unit() < self.drop_rate {
                continue; // drop
            }
            if self.rng.unit() < self.reorder_rate {
                self.pending.push(dg); // delay one round
                continue;
            }
            out.push(dg);
        }
        out
    }
}

/// A shared queue handle the endpoint sink writes into.
type LinkHandle = Rc<RefCell<LossyLink>>;

fn make_sink(link: LinkHandle) -> Box<dyn FnMut(&[u8])> {
    Box::new(move |dg: &[u8]| {
        link.borrow_mut().pending.push(dg.to_vec());
    })
}

/// One round: deliver both directions, update both ends, deliver standalone acks.
/// Mirrors test_net.cpp `pump`.
fn pump(
    a: &mut ReliableEndpoint,
    b: &mut ReliableEndpoint,
    ab: &LinkHandle,
    ba: &LinkHandle,
    clock: &mut f64,
) {
    *clock += 0.050;
    for dg in ab.borrow_mut().deliver() {
        b.on_datagram(&dg);
    }
    for dg in ba.borrow_mut().deliver() {
        a.on_datagram(&dg);
    }
    a.update(*clock);
    b.update(*clock);
    for dg in ab.borrow_mut().deliver() {
        b.on_datagram(&dg);
    }
    for dg in ba.borrow_mut().deliver() {
        a.on_datagram(&dg);
    }
}

// ===========================================================================
// Test 1 — ReliableOrdered: 200 messages A->B, 30% drop + 30% reorder.
//           B must receive ALL 200 in exact send order.
// ===========================================================================
#[test]
fn reliable_ordered() {
    const MSGS: i32 = 200;
    let link_ab: LinkHandle = Rc::new(RefCell::new(LossyLink::new(0xDEAD_BEEF, 0.30, 0.30)));
    let link_ba: LinkHandle = Rc::new(RefCell::new(LossyLink::new(0xCAFE_BABE, 0.30, 0.30)));

    let mut ep_b = ReliableEndpoint::new(make_sink(link_ba.clone()), 2);
    let mut ep_a = ReliableEndpoint::new(make_sink(link_ab.clone()), 1);

    let received: Rc<RefCell<Vec<i32>>> = Rc::new(RefCell::new(Vec::new()));
    let rx = received.clone();
    ep_b.set_receiver(Box::new(move |_ch, pl: &[u8]| {
        if pl.len() >= 4 {
            rx.borrow_mut()
                .push(i32::from_le_bytes(pl[..4].try_into().unwrap()));
        }
    }));

    for i in 0..MSGS {
        ep_a.send(NetChannel::ReliableOrdered, &i.to_le_bytes());
    }

    let mut clock = 0.0;
    let mut r = 0;
    while r < 2000 && (received.borrow().len() as i32) < MSGS {
        pump(&mut ep_a, &mut ep_b, &link_ab, &link_ba, &mut clock);
        r += 1;
    }

    let rec = received.borrow();
    assert_eq!(rec.len() as i32, MSGS, "all 200 messages received");
    for (i, &v) in rec.iter().enumerate() {
        assert_eq!(v, i as i32, "messages delivered in exact send order");
    }
}

// ===========================================================================
// Test 2 — ReliableUnordered: 30% drop; all 100 eventually arrive; no dups.
// ===========================================================================
#[test]
fn reliable_unordered() {
    const MSGS: i32 = 100;
    let link_ab: LinkHandle = Rc::new(RefCell::new(LossyLink::new(0x1234_5678, 0.30, 0.0)));
    let link_ba: LinkHandle = Rc::new(RefCell::new(LossyLink::new(0x8765_4321, 0.30, 0.0)));

    let mut ep_b = ReliableEndpoint::new(make_sink(link_ba.clone()), 2);
    let mut ep_a = ReliableEndpoint::new(make_sink(link_ab.clone()), 1);

    let received: Rc<RefCell<Vec<i32>>> = Rc::new(RefCell::new(Vec::new()));
    let rx = received.clone();
    ep_b.set_receiver(Box::new(move |_ch, pl: &[u8]| {
        if pl.len() >= 4 {
            rx.borrow_mut()
                .push(i32::from_le_bytes(pl[..4].try_into().unwrap()));
        }
    }));

    for i in 0..MSGS {
        ep_a.send(NetChannel::ReliableUnordered, &i.to_le_bytes());
    }

    let mut clock = 0.0;
    let mut r = 0;
    while r < 2000 && (received.borrow().len() as i32) < MSGS {
        pump(&mut ep_a, &mut ep_b, &link_ab, &link_ba, &mut clock);
        r += 1;
    }

    let mut sorted = received.borrow().clone();
    assert_eq!(sorted.len() as i32, MSGS, "all 100 messages eventually received");
    sorted.sort_unstable();
    for i in 1..sorted.len() {
        assert_ne!(sorted[i], sorted[i - 1], "no message delivered twice");
    }
}

// ===========================================================================
// Test 3 — Unreliable: 40% drop; B gets a subset; never delivers an older seq
//           after a newer one (newest-wins monotone).
// ===========================================================================
#[test]
fn unreliable() {
    const MSGS: i32 = 150;
    let link_ab: LinkHandle = Rc::new(RefCell::new(LossyLink::new(0xFEED_FACE, 0.40, 0.0)));

    // B's sink is a no-op (no acks needed for the unreliable test).
    let mut ep_b = ReliableEndpoint::new(Box::new(|_dg: &[u8]| {}), 2);
    let mut ep_a = ReliableEndpoint::new(make_sink(link_ab.clone()), 1);

    let received: Rc<RefCell<Vec<i32>>> = Rc::new(RefCell::new(Vec::new()));
    let monotone: Rc<RefCell<bool>> = Rc::new(RefCell::new(true));
    let last_val: Rc<RefCell<i32>> = Rc::new(RefCell::new(-1));
    let rx = received.clone();
    let mono = monotone.clone();
    let last = last_val.clone();
    ep_b.set_receiver(Box::new(move |_ch, pl: &[u8]| {
        if pl.len() >= 4 {
            let v = i32::from_le_bytes(pl[..4].try_into().unwrap());
            rx.borrow_mut().push(v);
            if v < *last.borrow() {
                *mono.borrow_mut() = false;
            }
            *last.borrow_mut() = v;
        }
    }));

    for i in 0..MSGS {
        ep_a.send(NetChannel::Unreliable, &i.to_le_bytes());
    }

    let mut clock = 0.0;
    for _ in 0..30 {
        clock += 0.050;
        for dg in link_ab.borrow_mut().deliver() {
            ep_b.on_datagram(&dg);
        }
        ep_a.update(clock);
        ep_b.update(clock);
    }

    let n = received.borrow().len() as i32;
    assert!(n > 0, "at least some messages delivered");
    assert!(n < MSGS, "not all messages delivered (drops expected)");
    assert!(
        *monotone.borrow(),
        "delivered sequence is monotonically non-decreasing (newest-wins)"
    );
}

// ===========================================================================
// Test 4 — Acks clear unacked: after lossless convergence the sender's
//           unacked_count returns to 0 (no infinite resend).
// ===========================================================================
#[test]
fn acks_clear_unacked() {
    const MSGS: i32 = 50;
    let link_ab: LinkHandle = Rc::new(RefCell::new(LossyLink::new(0x9999_AAAA, 0.30, 0.0)));
    let link_ba: LinkHandle = Rc::new(RefCell::new(LossyLink::new(0xBBBB_CCCC, 0.30, 0.0)));

    let mut ep_b = ReliableEndpoint::new(make_sink(link_ba.clone()), 2);
    let mut ep_a = ReliableEndpoint::new(make_sink(link_ab.clone()), 1);
    ep_b.set_receiver(Box::new(|_ch, _pl: &[u8]| {}));

    for i in 0..MSGS {
        ep_a.send(NetChannel::ReliableOrdered, &i.to_le_bytes());
    }

    let mut clock = 0.0;
    // Phase 1: lossy convergence.
    for _ in 0..500 {
        pump(&mut ep_a, &mut ep_b, &link_ab, &link_ba, &mut clock);
    }
    // Phase 2: lossless drain.
    link_ab.borrow_mut().set_lossless();
    link_ba.borrow_mut().set_lossless();
    let mut r = 0;
    while r < 500 && ep_a.unacked_count() > 0 {
        pump(&mut ep_a, &mut ep_b, &link_ab, &link_ba, &mut clock);
        r += 1;
    }

    assert_eq!(
        ep_a.unacked_count(),
        0,
        "after lossless convergence sender unacked_count == 0"
    );
}
