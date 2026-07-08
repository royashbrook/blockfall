//! Manual perf probes for comparing chunk/meshing changes across branches.
//!
//! Run with:
//!   cargo test --release perf_meshing_render_baseline -- --ignored --nocapture

use bfcore::abi::*;
use bfcore::chunk::PaletteChunk;
use bfcore::content::ContentRegistry;
use bfcore::mesher::GreedyMesher;
use bfcore::store::ChunkStore;
use bfcore::types::{ChunkCoord, CHUNK_DIM, CHUNK_VOL};
use bfcore::world::{self, World};

use std::hint::black_box;
use std::os::raw::c_void;
use std::time::{Duration, Instant};

extern "C" fn alloc_fn(_user: *mut c_void, bytes: u32) -> bf_gpu_buffer {
    let n = bytes.max(16) as usize;
    let mut v = vec![0u8; n];
    let p = v.as_mut_ptr();
    std::mem::forget(v);
    bf_gpu_buffer {
        handle: p as bf_handle,
        contents: p as *mut c_void,
        bytes,
    }
}

extern "C" fn free_fn(_user: *mut c_void, _handle: bf_handle) {
    // Perf tests run in one short process; leaking avoids a length side table.
}

fn allocator() -> bf_gpu_allocator {
    bf_gpu_allocator {
        user: std::ptr::null_mut(),
        alloc: Some(alloc_fn),
        free_: Some(free_fn),
    }
}

fn empty_frame() -> bf_render_frame {
    unsafe { std::mem::zeroed() }
}

fn content_path() -> String {
    format!("{}/../../content", env!("CARGO_MANIFEST_DIR"))
}

fn samples() -> usize {
    std::env::var("BF_PERF_SAMPLES")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .filter(|&n| n > 0)
        .unwrap_or(5)
}

fn make_flat_store() -> (ChunkStore, ChunkCoord) {
    let cc = ChunkCoord { x: 0, y: 0, z: 0 };
    let mut ch = PaletteChunk::new(cc, world::AIR);
    let h = (CHUNK_DIM / 2).max(1);
    for z in 0..CHUNK_DIM {
        for y in 0..h {
            for x in 0..CHUNK_DIM {
                let b = if y + 1 == h {
                    world::GRASS
                } else {
                    world::STONE
                };
                ch.set(x, y, z, b);
            }
        }
    }
    let mut store = ChunkStore::new();
    store.insert(ch);
    (store, cc)
}

fn make_checker_store() -> (ChunkStore, ChunkCoord) {
    let cc = ChunkCoord { x: 0, y: 0, z: 0 };
    let mut ch = PaletteChunk::new(cc, world::AIR);
    for z in 0..CHUNK_DIM {
        for y in 0..CHUNK_DIM {
            for x in 0..CHUNK_DIM {
                if (x ^ y ^ z) & 1 == 0 {
                    ch.set(x, y, z, world::STONE);
                }
            }
        }
    }
    let mut store = ChunkStore::new();
    store.insert(ch);
    (store, cc)
}

fn duration_ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}

fn report_mesh_case(label: &str, store: &ChunkStore, cc: ChunkCoord, n: usize) {
    let mesher = GreedyMesher::new();
    let (warm, _, _) = mesher.mesh(cc, store, false);
    assert!(!warm.empty, "{label} produced an empty mesh");

    let mut total = Duration::ZERO;
    let mut min = Duration::MAX;
    let mut last = warm;

    for _ in 0..n {
        let t0 = Instant::now();
        let (mr, vb, ib) = mesher.mesh(cc, store, false);
        let elapsed = t0.elapsed();
        black_box((&mr, vb.len(), ib.len()));
        total += elapsed;
        min = min.min(elapsed);
        last = mr;
    }

    let avg = total / n as u32;
    println!(
        "PERF_JSON {{\"case\":\"{}\",\"chunk_dim\":{},\"chunk_vol\":{},\"samples\":{},\"avg_ms\":{:.3},\"min_ms\":{:.3},\"vertex_bytes\":{},\"index_bytes\":{},\"index_count\":{}}}",
        label,
        CHUNK_DIM,
        CHUNK_VOL,
        n,
        duration_ms(avg),
        duration_ms(min),
        last.vertex_bytes,
        last.index_bytes,
        last.index_count
    );
}

fn total_indices(draws: &[bf_draw_item]) -> u64 {
    draws.iter().map(|d| d.index_count as u64).sum()
}

fn report_clean_frame_case(mut w: World<'_>, n: usize) {
    let mut frame = empty_frame();
    let mut draws = Vec::new();
    let mut shadow = Vec::new();
    let mut props = Vec::new();

    let t0 = Instant::now();
    w.build_frame(&mut frame, &mut draws, &mut shadow, &mut props, 0.0);
    let remesh = t0.elapsed();
    let first_draw_count = frame.draw_count;
    let first_shadow_count = frame.shadow_draw_count;
    let first_prop_count = frame.prop_instance_count;
    let first_indices = total_indices(&draws);
    assert!(
        first_draw_count > 0,
        "world frame produced no terrain draws"
    );
    assert!(first_indices > 0, "world frame produced no terrain indices");

    let mut total = Duration::ZERO;
    let mut min = Duration::MAX;
    for _ in 0..n {
        let t1 = Instant::now();
        w.build_frame(&mut frame, &mut draws, &mut shadow, &mut props, 0.0);
        let elapsed = t1.elapsed();
        black_box((
            frame.draw_count,
            frame.shadow_draw_count,
            frame.prop_instance_count,
        ));
        total += elapsed;
        min = min.min(elapsed);
    }

    let avg = total / n as u32;
    println!(
        "PERF_JSON {{\"case\":\"world_frame_remesh\",\"chunk_dim\":{},\"resident_chunks\":{},\"ms\":{:.3},\"draws\":{},\"shadow_draws\":{},\"props\":{},\"terrain_indices\":{}}}",
        CHUNK_DIM,
        w.debug_resident_count(),
        duration_ms(remesh),
        first_draw_count,
        first_shadow_count,
        first_prop_count,
        first_indices
    );
    println!(
        "PERF_JSON {{\"case\":\"world_frame_clean\",\"chunk_dim\":{},\"resident_chunks\":{},\"samples\":{},\"avg_ms\":{:.3},\"min_ms\":{:.3},\"draws\":{},\"shadow_draws\":{},\"props\":{},\"terrain_indices\":{}}}",
        CHUNK_DIM,
        w.debug_resident_count(),
        n,
        duration_ms(avg),
        duration_ms(min),
        frame.draw_count,
        frame.shadow_draw_count,
        frame.prop_instance_count,
        total_indices(&draws)
    );
}

fn make_flat_world() -> World<'static> {
    let content = Box::leak(Box::new(ContentRegistry::new()));
    assert!(content.load(&content_path()), "content load");

    let mut w = World::new(None);
    w.debug_set_sync_streaming(true);
    w.set_allocator(allocator());
    w.set_content(content);
    w.generate_test_world();
    w.debug_set_camera(8.5, 20.0, 8.5, 0.0, -1.2);
    w
}

#[test]
#[ignore = "manual perf probe; run with --ignored --nocapture"]
fn perf_meshing_render_baseline() {
    let n = samples();
    println!(
        "PERF_JSON {{\"case\":\"config\",\"chunk_dim\":{},\"chunk_vol\":{},\"samples\":{}}}",
        CHUNK_DIM, CHUNK_VOL, n
    );

    let (flat, flat_cc) = make_flat_store();
    report_mesh_case("mesh_flat_half_chunk", &flat, flat_cc, n);

    let (checker, checker_cc) = make_checker_store();
    report_mesh_case("mesh_checker_chunk", &checker, checker_cc, n);

    report_clean_frame_case(make_flat_world(), n);
}
