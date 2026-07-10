// ---------------------------------------------------------------------------
// Smooth anchor-lattice surface
//
// The raw height field is expensive, so we sample it on a coarse anchor lattice
// (every SEAM_ANCHOR_STEP blocks) and reconstruct per-column heights from those
// anchors. The reconstruction must be a pure function of (seed, wx, wz) that any
// chunk evaluates identically, which holds because the anchors themselves are
// pure functions of their lattice coordinates and every column reads the same
// 4x4 anchor neighborhood regardless of which chunk asks.
//
// The old reconstruction was a Lipschitz-1 cone envelope midpoint. Its tent
// geometry plus integer truncation terraced the world into lattice-aligned
// square plateaus (very visible underwater). We now use bicubic Catmull-Rom,
// which is C1 continuous across cell boundaries (no creases), and add a small
// high-frequency detail octave so quantization to whole blocks follows the
// noise contours instead of locking onto the anchor grid.
// ---------------------------------------------------------------------------
// #179: 12 -> 16 so the anchor lattice divides WORLD_PERIOD (2048 anchors
// across the torus). A bonus: the bicubic parameter t = (wx mod 16)/16 is now
// exact in f32, so a column queried from either side of the seam reconstructs
// the identical height bit for bit.
const SEAM_ANCHOR_STEP: i32 = 16;
const SEAM_ANCHOR_RADIUS: i32 = 5;

#[inline]
fn seam_floordiv(a: i32, b: i32) -> i32 {
    a / b - if a % b != 0 && (a ^ b) < 0 { 1 } else { 0 }
}

// Catmull-Rom spline through p1..p2 with tangents from p0/p3, t in [0,1].
#[inline]
fn catmull_rom(p0: f32, p1: f32, p2: f32, p3: f32, t: f32) -> f32 {
    let a = 2.0 * p1;
    let b = p2 - p0;
    let c = 2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3;
    let d = 3.0 * (p1 - p2) + p3 - p0;
    0.5 * (a + (b + (c + d * t) * t) * t)
}

// Smooth bicubic evaluation over the anchor lattice given an anchor-fetch
// closure. Reads the 4x4 anchors around the cell containing (wx, wz).
fn seam_smooth_eval<F: Fn(i32, i32) -> f32>(wx: i32, wz: i32, fetch: F) -> f32 {
    let acx = seam_floordiv(wx, SEAM_ANCHOR_STEP);
    let acz = seam_floordiv(wz, SEAM_ANCHOR_STEP);
    let tx = (wx - acx * SEAM_ANCHOR_STEP) as f32 / SEAM_ANCHOR_STEP as f32;
    let tz = (wz - acz * SEAM_ANCHOR_STEP) as f32 / SEAM_ANCHOR_STEP as f32;

    let mut rows = [0.0f32; 4];
    for (j, row) in rows.iter_mut().enumerate() {
        let gz = acz + j as i32 - 1;
        *row = catmull_rom(
            fetch(acx - 1, gz),
            fetch(acx, gz),
            fetch(acx + 1, gz),
            fetch(acx + 2, gz),
            tx,
        );
    }
    catmull_rom(rows[0], rows[1], rows[2], rows[3], tz)
}

// Fine post-interpolation relief: low amplitude, higher frequency than the
// anchor lattice, pure function of (seed, wx, wz). Roughly +-1.5 blocks. This
// breaks the integer-quantization plates without changing the macro shape.
const HEIGHT_DETAIL_SEED_MIX: u64 = 0x5EAF_00D5_0F7C_0A57;

#[inline]
fn height_detail(wx: i32, wz: i32, seed: u64) -> f32 {
    let dseed = fmix64(seed ^ HEIGHT_DETAIL_SEED_MIX);
    // #179: ~1/13 as period 2521; lacunarity was 2.6 which cannot close on the
    // torus, so fbm2's fixed 2.0 applies (second octave ~1/6.5 instead of 1/5;
    // this is the +-1.5 block fine relief, visual impact is negligible).
    let wx = wrap_world(wx);
    let wz = wrap_world(wz);
    (fbm2(wx as f32, wz as f32, dseed, 2, 2521, 0.55) * 2.0 - 1.0) * 1.5
}

// Slow on-demand path: raw anchor heights computed directly. Matches the cached
// path exactly because both read identical anchors and detail noise.
fn surface_height(wx: i32, wz: i32, seed: u64) -> i32 {
    let base = seam_smooth_eval(wx, wz, |gx, gz| {
        surface_height_raw_at(gx * SEAM_ANCHOR_STEP, gz * SEAM_ANCHOR_STEP, seed)
    });
    (base + height_detail(wx, wz, seed)).floor() as i32
}

// ---------------------------------------------------------------------------
// Chunk-local anchor cache
// ---------------------------------------------------------------------------
struct SeamAnchorCache {
    gx0: i32,
    gz0: i32,
    nx: i32,
    nz: i32,
    h: Vec<f32>,
    seed: u64,
}

impl SeamAnchorCache {
    fn at(&self, gx: i32, gz: i32) -> f32 {
        let mut ix = gx - self.gx0;
        let mut iz = gz - self.gz0;
        if ix < 0 {
            ix = 0;
        } else if ix >= self.nx {
            ix = self.nx - 1;
        }
        if iz < 0 {
            iz = 0;
        } else if iz >= self.nz {
            iz = self.nz - 1;
        }
        self.h[(iz * self.nx + ix) as usize]
    }
}

fn build_anchor_cache(wx_min: i32, wz_min: i32, seed: u64) -> SeamAnchorCache {
    let wx_max = wx_min + K_CHUNK_DIM - 1;
    let wz_max = wz_min + K_CHUNK_DIM - 1;
    let gxlo = seam_floordiv(wx_min, SEAM_ANCHOR_STEP) - SEAM_ANCHOR_RADIUS;
    let gxhi = seam_floordiv(wx_max, SEAM_ANCHOR_STEP) + SEAM_ANCHOR_RADIUS;
    let gzlo = seam_floordiv(wz_min, SEAM_ANCHOR_STEP) - SEAM_ANCHOR_RADIUS;
    let gzhi = seam_floordiv(wz_max, SEAM_ANCHOR_STEP) + SEAM_ANCHOR_RADIUS;

    let nx = gxhi - gxlo + 1;
    let nz = gzhi - gzlo + 1;
    let mut h = vec![0.0f32; (nx * nz) as usize];
    for iz in 0..nz {
        for ix in 0..nx {
            h[(iz * nx + ix) as usize] = surface_height_raw_at(
                (gxlo + ix) * SEAM_ANCHOR_STEP,
                (gzlo + iz) * SEAM_ANCHOR_STEP,
                seed,
            );
        }
    }
    SeamAnchorCache {
        gx0: gxlo,
        gz0: gzlo,
        nx,
        nz,
        h,
        seed,
    }
}

// Fast path over the prebuilt anchor cache. The cache covers the chunk's cells
// plus SEAM_ANCHOR_RADIUS, and the bicubic kernel only reaches 2 cells out, so
// every in-chunk query (and queries up to 3 cells outside) reads true anchors
// and matches surface_height exactly.
fn surface_height_cached(wx: i32, wz: i32, cache: &SeamAnchorCache) -> i32 {
    let base = seam_smooth_eval(wx, wz, |gx, gz| cache.at(gx, gz));
    (base + height_detail(wx, wz, cache.seed)).floor() as i32
}

// ---------------------------------------------------------------------------
// Per-chunk column cache
// ---------------------------------------------------------------------------
struct ChunkColumnCache {
    h: Vec<i32>,
    dom: Vec<Biome>,
    weights: Vec<[f32; NUM_BIOMES]>,
}

impl ChunkColumnCache {
    #[inline]
    fn idx(lx: i32, lz: i32) -> usize {
        (lz * K_CHUNK_DIM + lx) as usize
    }
}

fn build_column_cache(
    wx_min: i32,
    wz_min: i32,
    seed: u64,
    anchor_cache: &SeamAnchorCache,
) -> ChunkColumnCache {
    let mut out = ChunkColumnCache {
        h: vec![0; (K_CHUNK_DIM * K_CHUNK_DIM) as usize],
        dom: vec![Biome::Plains; (K_CHUNK_DIM * K_CHUNK_DIM) as usize],
        weights: vec![[0.0; NUM_BIOMES]; (K_CHUNK_DIM * K_CHUNK_DIM) as usize],
    };
    for lz in 0..K_CHUNK_DIM {
        for lx in 0..K_CHUNK_DIM {
            let wx = wx_min + lx;
            let wz = wz_min + lz;
            let i = ChunkColumnCache::idx(lx, lz);
            out.weights[i] = biome_weights(wx, wz, seed);
            out.dom[i] = voronoi_biome(wx, wz, seed);
            out.h[i] = surface_height_cached(wx, wz, anchor_cache);
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Shared per-column data, memoized across the Y stack and across worker threads.
//
// The anchor and column caches are pure functions of (seed, wx_min, wz_min), but a
// column of terrain spans several Y chunks (CY -1..3) and generate() used to rebuild
// both caches for every one of them: the same 256 columns of climate + voronoi +
// seam-cone height noise computed five times per column (about a third of total gen
// time, measured). This memo computes them once per column and shares the Arc.
//
// Determinism: the cached value is a pure function of the key, so a hit, a miss, a
// concurrent duplicate compute, or a cleared map all yield byte-identical chunks.
// The map is bounded (cleared at CAP) so long sessions cannot grow it unbounded.
// ---------------------------------------------------------------------------
struct SharedColumnData {
    anchors: SeamAnchorCache,
    cols: ChunkColumnCache,
}

fn shared_column_data(wx_min: i32, wz_min: i32, seed: u64) -> std::sync::Arc<SharedColumnData> {
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex, OnceLock};
    const CAP: usize = 512;
    static MEMO: OnceLock<Mutex<HashMap<(u64, i32, i32), Arc<SharedColumnData>>>> = OnceLock::new();
    let memo = MEMO.get_or_init(|| Mutex::new(HashMap::new()));
    // #179: canonical key AND canonical build frame, so torus-twin chunks share
    // one entry and the cached lattice frames line up with generate()'s own
    // canonicalized chunk coordinate.
    let wx_min = wrap_world(wx_min);
    let wz_min = wrap_world(wz_min);
    let key = (seed, wx_min, wz_min);
    if let Some(hit) = memo.lock().unwrap().get(&key) {
        return hit.clone();
    }
    // Compute outside the lock; a racing thread may duplicate the work but the
    // value is identical either way.
    let anchors = build_anchor_cache(wx_min, wz_min, seed);
    let cols = build_column_cache(wx_min, wz_min, seed, &anchors);
    let data = Arc::new(SharedColumnData { anchors, cols });
    let mut m = memo.lock().unwrap();
    if m.len() >= CAP {
        m.clear();
    }
    m.insert(key, data.clone());
    data
}
