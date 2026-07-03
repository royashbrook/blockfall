#[cfg(test)]
mod worldgen_tests {
    use super::*;
    const SEED: u64 = 11;

    // Same seed + coord must yield an identical chunk (no hidden global state).
    #[test]
    fn deterministic() {
        let (mut g1, mut g2) = (TerrainGen::new(), TerrainGen::new());
        g1.seed(SEED);
        g2.seed(SEED);
        for c in [
            ChunkCoord { x: 0, y: 0, z: 0 },
            ChunkCoord { x: 3, y: 1, z: -5 },
            ChunkCoord { x: 10, y: 2, z: 7 },
        ] {
            assert_eq!(g1.content_hash(c), g2.content_hash(c), "seed {SEED} chunk {c:?}");
        }
    }

    // Cities must be findable. A player who explores a reasonable area should reliably
    // run into at least one city, and cities should turn up at a healthy share of all
    // settlements (city + village) without carpeting the world. Scanning a wide area for
    // several seeds, every seed must yield a city within a modest distance of origin and
    // cities must be a substantial fraction of settlements (the #108 fix made them too
    // rare). Guards against regressing STRUCT_CITY_UPGRADE_THRESH back down.
    #[test]
    fn cities_are_findable() {
        for seed in [11u64, 1, 42, 7, 1234] {
            let (mut cities, mut villages) = (0i64, 0i64);
            let mut nearest_city2: i64 = i64::MAX;
            let r = 200; // structure cells; 200*64 = 12800 blocks half-extent each way
            for scz in -r..=r {
                for scx in -r..=r {
                    let sd = struct_for_cell(scx, scz, seed);
                    if !sd.present {
                        continue;
                    }
                    if sd.typ == STRUCT_CITY {
                        cities += 1;
                        let d2 = (sd.anchor_wx as i64).pow(2) + (sd.anchor_wz as i64).pow(2);
                        if d2 < nearest_city2 {
                            nearest_city2 = d2;
                        }
                    } else if sd.typ == STRUCT_VILLAGE {
                        villages += 1;
                    }
                }
            }
            let settlements = cities + villages;
            assert!(cities > 0, "seed {seed}: no cities found in scan");
            // A city should sit within a few thousand blocks of origin for every seed.
            let nearest = (nearest_city2 as f64).sqrt();
            assert!(
                nearest < 4000.0,
                "seed {seed}: nearest city {nearest:.0} blocks from origin is too far"
            );
            // Cities should be a meaningful share of settlements (target ~55-60% per the
            // tuned threshold), so a wandering player meets cities, not only villages.
            let share = cities as f64 / settlements as f64;
            assert!(
                share > 0.4,
                "seed {seed}: cities only {share:.2} of settlements ({cities}/{settlements}), too rare"
            );
        }
    }

    // The world is varied (the biome map is not collapsed to one type). Biomes are
    // large now, so scan a wide area to see the variety.
    #[test]
    fn biome_variety_near_origin() {
        let mut seen = [false; NUM_BIOMES];
        for wz in (-700..=700).step_by(25) {
            for wx in (-700..=700).step_by(25) {
                let b = worldgen_dominant_biome(wx, wz, SEED);
                if (b as usize) < NUM_BIOMES {
                    seen[b as usize] = true;
                }
            }
        }
        let n = seen.iter().filter(|&&s| s).count();
        assert!(n >= 5, "expected varied biomes in a wide scan, saw {n}: {seen:?}");
    }

    // #152: deserts should be dry sparse decoration, not a mushroom carpet. The
    // old desert-decoration pass placed MUSHROOM on sand at 42/256, which could
    // make desert spawn chunks dense and slow to build. Cactus / rocks are fine;
    // mushrooms are forest/swamp/plains food, not desert ground cover.
    #[test]
    fn desert_columns_do_not_generate_mushrooms() {
        let mut g = TerrainGen::new();
        g.seed(SEED);
        let mut desert_columns = 0;
        let mut chunks_checked = 0;
        'scan: for cz in -48..=48 {
            for cx in -48..=48 {
                let center_wx = cx * K_CHUNK_DIM + K_CHUNK_DIM / 2;
                let center_wz = cz * K_CHUNK_DIM + K_CHUNK_DIM / 2;
                if worldgen_dominant_biome(center_wx, center_wz, SEED) != Biome::Desert as i32 {
                    continue;
                }
                let c = ChunkCoord { x: cx, y: 0, z: cz };
                let mut chunk = DenseChunk::new(AIR);
                g.generate(c, &mut chunk);
                for lz in 0..K_CHUNK_DIM {
                    for lx in 0..K_CHUNK_DIM {
                        let wx = c.x * K_CHUNK_DIM + lx;
                        let wz = c.z * K_CHUNK_DIM + lz;
                        if worldgen_dominant_biome(wx, wz, SEED) != Biome::Desert as i32 {
                            continue;
                        }
                        desert_columns += 1;
                        for ly in 0..K_CHUNK_DIM {
                            let b = chunk.get(lx, ly, lz);
                            assert_ne!(
                                b, MUSHROOM,
                                "desert column generated a mushroom at world ({wx},{},{wz})",
                                c.y * K_CHUNK_DIM + ly
                            );
                        }
                    }
                }
                chunks_checked += 1;
                if chunks_checked >= 24 {
                    break 'scan;
                }
            }
        }

        assert!(desert_columns > 0, "sample set no longer covers desert columns");
    }

    #[test]
    fn desert_ground_cover_stays_sparse_and_dry() {
        let mut g = TerrainGen::new();
        g.seed(SEED);
        let mut desert_columns = 0;
        let mut desert_props = 0;
        let mut cacti = 0;
        let mut chunks_checked = 0;

        'scan: for cz in -64..=64 {
            for cx in -64..=64 {
                let center_wx = cx * K_CHUNK_DIM + K_CHUNK_DIM / 2;
                let center_wz = cz * K_CHUNK_DIM + K_CHUNK_DIM / 2;
                if worldgen_dominant_biome(center_wx, center_wz, SEED) != Biome::Desert as i32 {
                    continue;
                }

                // #171: the dune band sits around sea+8..sea+14, so desert
                // surfaces regularly cross the y=15/16 chunk boundary. Generate
                // the two bottom chunks and read the stack, so the sample
                // covers dune crests as well as troughs.
                let mut chunk0 = DenseChunk::new(AIR);
                let mut chunk1 = DenseChunk::new(AIR);
                g.generate(ChunkCoord { x: cx, y: 0, z: cz }, &mut chunk0);
                g.generate(ChunkCoord { x: cx, y: 1, z: cz }, &mut chunk1);
                let get_wy = |lx: i32, wy: i32, lz: i32| -> BlockId {
                    if wy < K_CHUNK_DIM {
                        chunk0.get(lx, wy, lz)
                    } else {
                        chunk1.get(lx, wy - K_CHUNK_DIM, lz)
                    }
                };

                for lz in 0..K_CHUNK_DIM {
                    for lx in 0..K_CHUNK_DIM {
                        let wx = cx * K_CHUNK_DIM + lx;
                        let wz = cz * K_CHUNK_DIM + lz;
                        if worldgen_dominant_biome(wx, wz, SEED) != Biome::Desert as i32 {
                            continue;
                        }

                        let h = worldgen_surface_height(wx, wz, SEED);
                        if h <= SEA_LEVEL {
                            continue;
                        }
                        if h < 0 || h + 1 >= 2 * K_CHUNK_DIM {
                            continue;
                        }
                        let surf = get_wy(lx, h, lz);
                        if surf != SAND && surf != STONE && surf != GRAVEL {
                            continue;
                        }

                        desert_columns += 1;
                        let b = get_wy(lx, h + 1, lz);
                        assert_ne!(
                            b, TALL_GRASS,
                            "dry desert surface generated tall grass at world ({wx},{},{wz})",
                            h + 1
                        );
                        assert_ne!(
                            b, FLOWER_RED,
                            "dry desert surface generated red flowers at world ({wx},{},{wz})",
                            h + 1
                        );
                        assert_ne!(
                            b, FLOWER_YELLOW,
                            "dry desert surface generated yellow flowers at world ({wx},{},{wz})",
                            h + 1
                        );
                        assert_ne!(
                            b, BERRY_BUSH,
                            "dry desert surface generated berry bush at world ({wx},{},{wz})",
                            h + 1
                        );

                        if b == CACTUS_PLANT || b == PEBBLE || b == FALLEN_STICK {
                            desert_props += 1;
                        }
                        if b == CACTUS_PLANT {
                            cacti += 1;
                        }
                    }
                }

                chunks_checked += 1;
                // #171 note: the dune band (roughly sea+8..sea+14) leaves fewer
                // in-window surface cells per y=0 chunk than the old desert
                // terrain did, so scan more chunks to keep the sample large
                // enough that the density ratio is statistics, not noise.
                if chunks_checked >= 96 {
                    break 'scan;
                }
            }
        }

        assert!(desert_columns > 0, "sample set no longer covers desert columns");
        assert!(
            desert_props * 100 <= desert_columns * 4,
            "desert props too dense: {desert_props} props across {desert_columns} columns"
        );
        assert!(
            cacti * 100 <= desert_columns * 2,
            "desert cactus too dense: {cacti} cacti across {desert_columns} columns"
        );
    }

    // Biome borders must NOT be axis-aligned straight lines (#: natural, eroded
    // transitions via the domain warp). An un-warped Voronoi map has boundaries that
    // run along long, straight perpendicular-bisector segments: where two biomes
    // meet, the same vertical edge (biome A on the left, biome B on the right) repeats
    // for many rows in a row, forming a wall. The domain warp bends those boundaries,
    // so such long straight vertical runs become rare and the border meanders instead.
    //
    // We build a biome grid, find every vertical boundary edge (a column whose biome
    // differs from its right neighbour), and measure the fraction of those edges that
    // are part of a straight vertical run of length >= RUN: the same A|B edge holding
    // for RUN consecutive rows. A straight, axis-aligned map keeps that fraction high;
    // the warp drives it down. Measured: ~0.20 un-warped vs ~0.15 with the warp.
    #[test]
    fn biome_borders_are_not_axis_aligned() {
        const LO: i32 = -600;
        const HI: i32 = 600;
        const RUN: i32 = 6; // rows of identical A|B edge that count as a straight wall
        let n = (HI - LO) as usize + 1;

        let mut grid = vec![0i32; n * n];
        for (iz, wz) in (LO..=HI).enumerate() {
            for (ix, wx) in (LO..=HI).enumerate() {
                grid[iz * n + ix] = worldgen_dominant_biome(wx, wz, SEED);
            }
        }
        let at = |ix: i32, iz: i32| grid[iz as usize * n + ix as usize];

        let mut vert_edges = 0i64;
        let mut vert_in_run = 0i64;
        for iz in 0..n as i32 {
            for ix in 0..n as i32 - 1 {
                let a = at(ix, iz);
                let b = at(ix + 1, iz);
                if a == b {
                    continue;
                }
                vert_edges += 1;
                // Is this the top of (or inside) a straight A|B run of RUN rows?
                let mut straight = true;
                for d in 1..RUN {
                    let z2 = iz + d;
                    if z2 >= n as i32 || at(ix, z2) != a || at(ix + 1, z2) != b {
                        straight = false;
                        break;
                    }
                }
                if straight {
                    vert_in_run += 1;
                }
            }
        }

        assert!(
            vert_edges > 2000,
            "too few biome boundary edges sampled ({vert_edges}); cannot judge border shape"
        );
        let frac_straight = vert_in_run as f64 / vert_edges as f64;

        // Un-warped Voronoi measures ~0.20 here; the warp pulls it to ~0.15. Require
        // the border to be clearly less wall-like than the un-warped grid. A regression
        // that flattened the warp (or removed it) would push this back toward 0.20.
        assert!(
            frac_straight < 0.18,
            "biome borders look axis-aligned: {:.3} of boundary edges sit in straight \
             vertical runs of >= {RUN} rows ({vert_in_run}/{vert_edges}); expected a \
             wavy, eroded border (un-warped is ~0.20)",
            frac_straight
        );
    }

    // #171: deserts are low relief dune fields. Wherever the world RENDERS as
    // desert (the Voronoi region), the surface must sit in a gentle band (the
    // dune compression in surface_height_raw), not inherit mountain scale
    // relief from the climate weight blend. Scan a wide area, collect
    // desert-interior land columns, and require the p95 absolute deviation
    // from the median height to stay small.
    #[test]
    fn desert_relief_is_bounded() {
        // Seed 78 regression-pins the sand-covered-mountain case: near its
        // origin the Voronoi map paints Desert over columns whose own climate
        // weights are pure Mountains, so a climate-weight-only damp left
        // heights up to ~56 there while everything rendered as sand.
        for seed in [SEED, 78] {
            let mut hs: Vec<i32> = Vec::new();
            for wz in (-2000..=2000).step_by(9) {
                for wx in (-2000..=2000).step_by(9) {
                    if worldgen_dominant_biome(wx, wz, seed) != Biome::Desert as i32 {
                        continue;
                    }
                    // Interior of the desert region only: across the border
                    // band the compression is deliberately partial so the
                    // terrain blends into the neighbour biome.
                    if desert_region_t(wx, wz, seed) < 0.75 {
                        continue;
                    }
                    // Land columns only: a desert region overlapping open
                    // ocean keeps its sea floor by design.
                    if is_ocean_column(wx as f32, wz as f32, seed) {
                        continue;
                    }
                    hs.push(surface_height(wx, wz, seed));
                }
            }
            assert!(
                hs.len() > 500,
                "seed {seed}: sample set only found {} desert-interior land columns; widen the scan",
                hs.len()
            );
            hs.sort_unstable();
            let median = hs[hs.len() / 2];
            let mut devs: Vec<i32> = hs.iter().map(|h| (h - median).abs()).collect();
            devs.sort_unstable();
            let p95 = devs[devs.len() * 95 / 100];
            let max = *devs.last().unwrap();
            println!(
                "seed {seed}: desert relief: {} columns, median h {}, p95 |dev| {}, max |dev| {}",
                hs.len(),
                median,
                p95,
                max
            );
            assert!(
                p95 <= 6,
                "seed {seed}: desert relief too mountainous: p95 |h - median| = {p95} blocks \
                 (median {median}, {} columns); deserts should be gentle dunes",
                hs.len()
            );
        }
    }

    // #172: biomes are ~4x the area they were. Sanity-check the scale by flood
    // filling connected same-biome patches on a coarse grid and measuring the
    // mean patch area. (Scanline run length is NOT a good metric here: the
    // domain warp zigzags a scanline back and forth across each wavy border,
    // so doubling WARP_AMP adds crossings that cancel out the fewer borders.)
    // Measured at seed 11 on this grid:
    //   pre-#172  (BIOME_CELL 132, climate freq 1/216, WARP_AMP 24):
    //     mean patch area  42,947 blocks^2 over 540 patches.
    //   with #172 (BIOME_CELL 264, climate freq 1/432, WARP_AMP 48):
    //     mean patch area 143,113 blocks^2 over 162 patches (~3.3x measured;
    //     the finite scan window truncates the biggest patches, so this
    //     understates the true area ratio).
    // The floor sits between the two so shrinking biomes back trips this test.
    #[test]
    fn biome_scale_mean_patch_area() {
        const STEP: i32 = 16;
        const LO: i32 = -2400;
        const HI: i32 = 2400;
        let n = ((HI - LO) / STEP) as usize + 1;
        let mut grid = vec![0i32; n * n];
        for iz in 0..n {
            for ix in 0..n {
                grid[iz * n + ix] =
                    worldgen_dominant_biome(LO + ix as i32 * STEP, LO + iz as i32 * STEP, SEED);
            }
        }
        // Flood fill connected components (4-neighbour).
        let mut comp = vec![-1i32; n * n];
        let mut sizes: Vec<i64> = Vec::new();
        for start in 0..n * n {
            if comp[start] >= 0 {
                continue;
            }
            let id = sizes.len() as i32;
            let b = grid[start];
            let mut stack = vec![start];
            comp[start] = id;
            let mut size = 0i64;
            while let Some(i) = stack.pop() {
                size += 1;
                let (ix, iz) = (i % n, i / n);
                let mut push = |j: usize| {
                    if comp[j] < 0 && grid[j] == b {
                        comp[j] = id;
                        stack.push(j);
                    }
                };
                if ix > 0 {
                    push(i - 1);
                }
                if ix + 1 < n {
                    push(i + 1);
                }
                if iz > 0 {
                    push(i - n);
                }
                if iz + 1 < n {
                    push(i + n);
                }
            }
            sizes.push(size);
        }
        // Ignore tiny warp slivers (under 4 cells); they are border texture, not
        // biomes, and their count is warp-amplitude noise.
        let patches: Vec<i64> = sizes.into_iter().filter(|&s| s >= 4).collect();
        let cell_area = (STEP * STEP) as f64;
        let mean_area =
            patches.iter().sum::<i64>() as f64 / patches.len() as f64 * cell_area;
        println!(
            "mean biome patch area: {:.0} blocks^2 ({} patches)",
            mean_area,
            patches.len()
        );
        assert!(
            mean_area > 90_000.0,
            "biomes too small: mean patch area {mean_area:.0} blocks^2 \
             (pre-#172 measured ~43k, #172 target ~143k)"
        );
    }

    // The coastal gate: classify_climate_excluding never returns the excluded biome.
    #[test]
    fn exclude_skips_biome() {
        // Beach-ish climate, excluding Beach, must pick something else.
        let b = classify_climate_excluding(0.78, 0.55, Biome::Beach as i32);
        assert_ne!(b, Biome::Beach as i32);
    }

    // Structure variety: scanning a wide area for seed 11 must turn up more than one
    // structure type, and must include at least one of the big / ruined structures
    // (tall tower, keep, ruin, or city). Catches a regression that collapses the
    // structure roster back to only small buildings.
    #[test]
    fn structure_variety_has_big_and_ruined() {
        let mut seen = std::collections::HashSet::new();
        let mut saw_big = false;
        let mut saw_ruin = false;
        let mut saw_city = false;
        // Scan structure cells over a wide region (cell size 64, so this is a big
        // area in blocks).
        for scz in -60..=60 {
            for scx in -60..=60 {
                let sd = struct_for_cell(scx, scz, SEED);
                if !sd.present {
                    continue;
                }
                seen.insert(sd.typ);
                if sd.typ == STRUCT_TALL_TOWER
                    || sd.typ == STRUCT_KEEP
                    || sd.typ == STRUCT_RUIN
                    || sd.typ == STRUCT_CITY
                {
                    saw_big = true;
                }
                if sd.typ == STRUCT_RUIN {
                    saw_ruin = true;
                }
                if sd.typ == STRUCT_CITY {
                    saw_city = true;
                }
            }
        }
        assert!(seen.len() > 1, "expected more than one structure type, saw {seen:?}");
        assert!(saw_big, "expected at least one big structure (tower/keep/ruin/city), types {seen:?}");
        assert!(saw_ruin, "expected at least one ruin in the scan, types {seen:?}");
        assert!(saw_city, "expected at least one city in the scan, types {seen:?}");
    }




    // No structure may have its anchor in deep ocean. struct_for_cell already gates
    // on surface height <= SEA_LEVEL; this guards that gate and also confirms anchors
    // are never on an ocean column.
    #[test]
    fn no_structure_in_deep_ocean() {
        for scz in -80..=80 {
            for scx in -80..=80 {
                let sd = struct_for_cell(scx, scz, SEED);
                if !sd.present {
                    continue;
                }
                let h = struct_surface(sd.anchor_wx, sd.anchor_wz, SEED);
                assert!(
                    h > SEA_LEVEL,
                    "structure type {} anchored at ({},{}) with surface {h} <= SEA_LEVEL {SEA_LEVEL}",
                    sd.typ,
                    sd.anchor_wx,
                    sd.anchor_wz
                );
                assert!(
                    !is_ocean_column(sd.anchor_wx as f32, sd.anchor_wz as f32, SEED),
                    "structure type {} anchored on an ocean column at ({},{})",
                    sd.typ,
                    sd.anchor_wx,
                    sd.anchor_wz
                );
            }
        }
    }

    // A ruined site must register as a danger marker: somewhere in a wide scan there
    // is a ruin, and worldgen_dangerous_site_near reports it (so the creature system
    // has a hostile-spawn anchor independent of the night/quest gate).
    #[test]
    fn ruin_registers_danger_marker() {
        // Find a ruin anchor.
        let mut ruin: Option<(i32, i32)> = None;
        'outer: for scz in -60..=60 {
            for scx in -60..=60 {
                let sd = struct_for_cell(scx, scz, SEED);
                if sd.present && sd.typ == STRUCT_RUIN {
                    ruin = Some((sd.anchor_wx, sd.anchor_wz));
                    break 'outer;
                }
            }
        }
        let (rx, rz) = ruin.expect("expected at least one ruin in the scan area");
        // Query right at the ruin: the danger-site lookup must return its anchor.
        let site = worldgen_dangerous_site_near(rx, rz, 48, SEED);
        let (ax, _ay, az) = site.expect("dangerous_site_near found no ruin at a known ruin");
        // #179: the lookup canonicalizes anchors onto the torus, so compare the
        // wrapped coordinates (the scan above may find a negative-frame cell).
        assert_eq!(
            (ax, az),
            (wrap_world(rx), wrap_world(rz)),
            "danger marker did not point at the ruin anchor"
        );
        // And a non-ruin location far from any ruin must report no danger marker when
        // we shrink the radius to zero around an arbitrary empty cell center.
        // (Sanity: querying with radius 0 at the ruin still finds it.)
        let exact = worldgen_dangerous_site_near(rx, rz, 0, SEED);
        assert!(exact.is_some(), "radius 0 at the ruin anchor should still match");
    }

    // -----------------------------------------------------------------------
    // Oceans + rivers (#: real water).
    //
    // Sample the surface height on a coarse grid over a large area. A grid cell is
    // "water" when its surface sits at/below sea level. Flood-fill (4-connected)
    // to find connected water bodies; the largest is the ocean. We also walk the
    // river channel field and require at least one river cell adjacent to ocean
    // water (a river that reaches the sea), and we require a healthy land fraction
    // so the world is still playable (not drowned).
    // -----------------------------------------------------------------------

    // Grid in world blocks: STEP blocks per cell, N x N cells, centred on origin.
    const OR_STEP: i32 = 8;
    const OR_N: i32 = 220; // 220 * 8 = 1760 blocks across, ~3M blocks scanned

    fn or_sample(seed: u64) -> (Vec<bool>, i32) {
        // water[i] = surface <= SEA_LEVEL at that grid cell.
        let n = OR_N as usize;
        let mut water = vec![false; n * n];
        let half = OR_N / 2;
        for gz in 0..OR_N {
            for gx in 0..OR_N {
                let wx = (gx - half) * OR_STEP;
                let wz = (gz - half) * OR_STEP;
                let h = worldgen_surface_height(wx, wz, seed);
                water[(gz * OR_N + gx) as usize] = h <= SEA_LEVEL;
            }
        }
        (water, OR_N)
    }

    // Largest connected water body (4-connected), returned as (size_in_cells,
    // label_grid). label == component id, or -1 for land.
    fn or_largest_body(water: &[bool], n: i32) -> (i32, Vec<i32>) {
        let mut label = vec![-1i32; (n * n) as usize];
        let mut next = 0i32;
        let mut best = 0i32;
        let mut best_label = -1i32;
        let mut stack: Vec<(i32, i32)> = Vec::new();
        for sz in 0..n {
            for sx in 0..n {
                let si = (sz * n + sx) as usize;
                if !water[si] || label[si] != -1 {
                    continue;
                }
                let id = next;
                next += 1;
                let mut size = 0;
                stack.push((sx, sz));
                label[si] = id;
                while let Some((cx, cz)) = stack.pop() {
                    size += 1;
                    for (dx, dz) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nx = cx + dx;
                        let nz = cz + dz;
                        if nx < 0 || nz < 0 || nx >= n || nz >= n {
                            continue;
                        }
                        let ni = (nz * n + nx) as usize;
                        if water[ni] && label[ni] == -1 {
                            label[ni] = id;
                            stack.push((nx, nz));
                        }
                    }
                }
                if size > best {
                    best = size;
                    best_label = id;
                }
            }
        }
        // Re-label so the biggest body is 0 and everything else is -1, for callers.
        let mut out = vec![-1i32; (n * n) as usize];
        for i in 0..out.len() {
            if label[i] == best_label {
                out[i] = 0;
            }
        }
        (best, out)
    }

    // Diagnostic dump (ignored by default): prints land fraction, ocean size, and
    // whether a river reaches the sea. Run with:
    //   cargo test --release oceans_diag -- --ignored --nocapture
    #[test]
    #[ignore]
    fn oceans_diag() {
        for seed in [11u64, 1, 7, 42, 24, 1234] {
            let (water, n) = or_sample(seed);
            let total = (n * n) as f32;
            let water_cells = water.iter().filter(|&&w| w).count() as f32;
            let land_frac = 1.0 - water_cells / total;
            let (ocean_cells, ocean) = or_largest_body(&water, n);
            // ocean span in blocks (bounding box diagonal-ish: max extent).
            let mut minx = n;
            let mut maxx = 0;
            let mut minz = n;
            let mut maxz = 0;
            for gz in 0..n {
                for gx in 0..n {
                    if ocean[(gz * n + gx) as usize] == 0 {
                        minx = minx.min(gx);
                        maxx = maxx.max(gx);
                        minz = minz.min(gz);
                        maxz = maxz.max(gz);
                    }
                }
            }
            let span_x = (maxx - minx) * OR_STEP;
            let span_z = (maxz - minz) * OR_STEP;
            let ocean_blocks = ocean_cells * OR_STEP * OR_STEP;

            // River reach: count channel cells and channel cells touching ocean.
            let half = n / 2;
            let mut river_cells = 0;
            let mut river_to_sea = 0;
            for gz in 0..n {
                for gx in 0..n {
                    let wx = (gx - half) * OR_STEP;
                    let wz = (gz - half) * OR_STEP;
                    if river_channel_t(wx as f32, wz as f32, seed) > 0.4
                        && !is_ocean_column(wx as f32, wz as f32, seed)
                    {
                        river_cells += 1;
                        // adjacent ocean cell?
                        for (dx, dz) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                            let nx = gx + dx;
                            let nz = gz + dz;
                            if nx >= 0 && nz >= 0 && nx < n && nz < n && ocean[(nz * n + nx) as usize] == 0 {
                                river_to_sea += 1;
                            }
                        }
                    }
                }
            }
            println!(
                "seed {seed}: land {:.1}% | ocean {ocean_cells} cells (~{ocean_blocks} blocks, span {span_x}x{span_z}) | river cells {river_cells}, touching sea {river_to_sea}",
                land_frac * 100.0
            );
        }
    }

    // -----------------------------------------------------------------------
    // Structures sit on the ground (#108 floating-structures regression).
    //
    // We stamp a single structure into an unbounded HashMap-backed grid by
    // running place_structure across every chunk window its footprint can reach
    // (terrain is NOT generated into these windows, so every non-AIR cell is a
    // structure block). Then, per column, we find the lowest structure block and
    // require it to rest on the terrain surface (no air gap beneath it). The
    // terrain top for a column is worldgen_surface_height(); a foundation column
    // that fills down to its own terrain has its lowest block at surface+1, so a
    // structure conforms when every occupied column's lowest block is at or below
    // surface+1. A block left floating in the air (lowest > surface+1) is a
    // floater. This catches the regression on sloped / mountain sites where a big
    // structure stamped at a single flat base Y leaves its downhill columns
    // hanging.
    // -----------------------------------------------------------------------

    // An unbounded grid that satisfies the Chunk trait for one fixed chunk window
    // at a time. place_* writes through struct_set, which clamps to [wx_min..],
    // so we re-point the window and replay to capture the whole footprint.
    struct GridChunk {
        wx_min: i32,
        wy_min: i32,
        wz_min: i32,
        cells: std::collections::HashMap<(i32, i32, i32), BlockId>,
    }
    impl Chunk for GridChunk {
        fn get(&self, lx: i32, ly: i32, lz: i32) -> BlockId {
            *self
                .cells
                .get(&(self.wx_min + lx, self.wy_min + ly, self.wz_min + lz))
                .unwrap_or(&AIR)
        }
        fn set(&mut self, lx: i32, ly: i32, lz: i32, b: BlockId) {
            self.cells
                .insert((self.wx_min + lx, self.wy_min + ly, self.wz_min + lz), b);
        }
    }

    // Stamp one structure into a global cell map by sweeping every chunk window
    // (x,z and the full vertical span) that its reach can touch.
    fn stamp_structure(sd: &StructDesc, seed: u64) -> std::collections::HashMap<(i32, i32, i32), BlockId> {
        let mut cells: std::collections::HashMap<(i32, i32, i32), BlockId> = std::collections::HashMap::new();
        let cx0 = seam_floordiv_pub(sd.anchor_wx - STRUCT_MAX_REACH_XZ, K_CHUNK_DIM);
        let cx1 = seam_floordiv_pub(sd.anchor_wx + STRUCT_MAX_REACH_XZ, K_CHUNK_DIM);
        let cz0 = seam_floordiv_pub(sd.anchor_wz - STRUCT_MAX_REACH_XZ, K_CHUNK_DIM);
        let cz1 = seam_floordiv_pub(sd.anchor_wz + STRUCT_MAX_REACH_XZ, K_CHUNK_DIM);
        // Vertical: structures rise well above terrain; cover a generous band of
        // chunk layers around the anchor surface.
        let base = struct_surface(sd.anchor_wx, sd.anchor_wz, seed);
        // Cover the foundation fill below (down to footprint terrain) and the tallest
        // crown above. Towers rise ~19, foundations fill at most a footprint spread.
        let cy0 = seam_floordiv_pub(base - 24, K_CHUNK_DIM);
        let cy1 = seam_floordiv_pub(base + 28, K_CHUNK_DIM);
        for cy in cy0..=cy1 {
            for cz in cz0..=cz1 {
                for cx in cx0..=cx1 {
                    let (wx_min, wy_min, wz_min) =
                        (cx * K_CHUNK_DIM, cy * K_CHUNK_DIM, cz * K_CHUNK_DIM);
                    let mut g = GridChunk {
                        wx_min,
                        wy_min,
                        wz_min,
                        cells: std::mem::take(&mut cells),
                    };
                    place_structure(sd, seed, &mut g, wx_min, wy_min, wz_min);
                    cells = g.cells;
                }
            }
        }
        cells
    }

    // floordiv helper available to tests (mirrors the private seam_floordiv).
    fn seam_floordiv_pub(a: i32, b: i32) -> i32 {
        a / b - if a % b != 0 && (a ^ b) < 0 { 1 } else { 0 }
    }

    // Returns the number of floating columns and a sample (typ, wx, wz, lowest_y,
    // surface) for the first floater found.
    fn structure_floaters(sd: &StructDesc, seed: u64) -> (i32, Option<(i32, i32, i32, i32, i32)>) {
        let cells = stamp_structure(sd, seed);
        // Per (wx,wz) column: lowest solid structure block and how many solid
        // blocks it has.
        let mut low: std::collections::HashMap<(i32, i32), (i32, i32)> = std::collections::HashMap::new();
        for (&(wx, wy, wz), &b) in cells.iter() {
            if b == AIR {
                continue;
            }
            let e = low.entry((wx, wz)).or_insert((i32::MAX, 0));
            if wy < e.0 {
                e.0 = wy;
            }
            e.1 += 1;
        }
        let mut floaters = 0;
        let mut sample = None;
        for (&(wx, wz), &(y_low, count)) in low.iter() {
            let surf = worldgen_surface_height(wx, wz, seed);
            // A genuine floater is a wall / foundation element (a stack of 2+ blocks)
            // whose base hangs well above the terrain with clear air beneath it. We
            // require:
            //  - lowest block more than a door-height above terrain (surf+4 tolerates
            //    a doorway / gate lintel that opens over existing ground), and
            //  - at least 2 blocks in the column, which excludes the deliberate
            //    single-block roof eave overhang every cabin / hut has (and which the
            //    player confirmed reads fine).
            if y_low > surf + 4 && count >= 2 {
                floaters += 1;
                if sample.is_none() {
                    sample = Some((sd.typ, wx, wz, y_low, surf));
                }
            }
        }
        (floaters, sample)
    }


    // A villager home (place_hut) is a real building: >= 5x5 footprint, a door
    // opening, windows, an interior air cavity, and a bed. This drives place_hut
    // directly through the public scan and also confirms it is deterministic.
    #[test]
    fn villager_home_real_building_unit() {
        for &seed in &[11u64, 7, 42, 1, 99] {
            let s = worldgen_villager_home_scan(seed);
            assert!(s.width >= 5 && s.depth >= 5, "seed {seed}: {}x{} < 5x5", s.width, s.depth);
            assert_eq!(s.door_blocks, 2, "seed {seed}: door opening missing");
            assert!(s.window_blocks >= 2, "seed {seed}: too few windows ({})", s.window_blocks);
            assert!(s.interior_air >= 9, "seed {seed}: interior cavity {} < 3x3", s.interior_air);
            assert!(s.bed_blocks >= 1, "seed {seed}: no bed");
            assert!(s.on_ground, "seed {seed}: home floats");
            // Determinism: a second scan must be identical.
            let s2 = worldgen_villager_home_scan(seed);
            assert_eq!(
                (s.width, s.depth, s.door_blocks, s.window_blocks, s.bed_blocks, s.interior_air),
                (s2.width, s2.depth, s2.door_blocks, s2.window_blocks, s2.bed_blocks, s2.interior_air),
                "seed {seed}: home scan not deterministic"
            );
        }
    }

    // Big structures (tower / keep / ruin / city) must conform to the ground with
    // no floating columns, including on sloped / mountain sites. Scan an area and
    // stamp every tower / keep / ruin (the #108 regression structures); cities are
    // mostly huts / cabins whose foundation logic is shared, so we cap how many we
    // stamp (each city is large and slow to stamp) while still exercising several.
    #[test]
    fn big_structures_sit_on_ground() {
        let mut total_cities = 0;
        let mut total_mountains = 0;
        for &seed in &[11u64, 7, 42] {
            let mut checked = 0;
            let mut mountain_checked = 0;
            let mut cities_checked = 0;
            const CITY_CAP: i32 = 2;
            for scz in -14..=14 {
                for scx in -14..=14 {
                    let sd = struct_for_cell(scx, scz, seed);
                    if !sd.present {
                        continue;
                    }
                    let small_big = sd.typ == STRUCT_TALL_TOWER
                        || sd.typ == STRUCT_KEEP
                        || sd.typ == STRUCT_RUIN;
                    let is_city = sd.typ == STRUCT_CITY;
                    if !small_big && !is_city {
                        continue;
                    }
                    if is_city {
                        if cities_checked >= CITY_CAP {
                            continue;
                        }
                        cities_checked += 1;
                    }
                    checked += 1;
                    if voronoi_biome(sd.anchor_wx, sd.anchor_wz, seed) == Biome::Mountains {
                        mountain_checked += 1;
                    }
                    let (floaters, sample) = structure_floaters(&sd, seed);
                    assert_eq!(
                        floaters, 0,
                        "seed {seed}: structure {sample:?} has {floaters} floating columns"
                    );
                }
            }
            assert!(checked > 0, "seed {seed}: found no big structures to check");
            total_cities += cities_checked;
            total_mountains += mountain_checked;
            println!(
                "seed {seed}: {checked} big structures checked ({mountain_checked} in mountains, {cities_checked} cities), 0 floaters"
            );
        }
        // Across the seeds we must have exercised the city path and several mountain
        // (sloped) sites, so the no-floater guarantee covers the hard cases.
        assert!(total_cities > 0, "no city was exercised across the seeds");
        assert!(total_mountains >= 3, "too few mountain sites exercised ({total_mountains})");
    }

    // Regression: seed 11 must have a large ocean, rivers that reach the sea, and a
    // playable land fraction. Numbers are deliberately loose so terrain re-tuning
    // does not make this brittle, while still catching "no real ocean" or "world
    // drowned" regressions.
    #[test]
    fn oceans_and_rivers() {
        let seed = SEED; // 11
        let (water, n) = or_sample(seed);
        let total = (n * n) as f32;
        let water_cells = water.iter().filter(|&&w| w).count() as f32;
        let land_frac = 1.0 - water_cells / total;

        // Playable: not drowned, not bone dry.
        assert!(
            (0.40..=0.75).contains(&land_frac),
            "land fraction {:.1}% out of healthy 40-75% range",
            land_frac * 100.0
        );

        // A real ocean: the largest connected water body must be big. Each cell is
        // OR_STEP^2 = 64 blocks; require >= 4000 cells (~256k blocks, hundreds of
        // blocks across), i.e. far bigger than a pond.
        let (ocean_cells, ocean) = or_largest_body(&water, n);
        assert!(
            ocean_cells >= 4000,
            "largest water body only {ocean_cells} grid cells; expected a real ocean (>= 4000)"
        );

        // Ocean spatial extent: span at least 200 blocks in each axis.
        let mut minx = n;
        let mut maxx = 0;
        let mut minz = n;
        let mut maxz = 0;
        for gz in 0..n {
            for gx in 0..n {
                if ocean[(gz * n + gx) as usize] == 0 {
                    minx = minx.min(gx);
                    maxx = maxx.max(gx);
                    minz = minz.min(gz);
                    maxz = maxz.max(gz);
                }
            }
        }
        let span_x = (maxx - minx) * OR_STEP;
        let span_z = (maxz - minz) * OR_STEP;
        assert!(
            span_x >= 200 && span_z >= 200,
            "ocean too small: span {span_x}x{span_z} blocks (want >= 200 each)"
        );

        // Rivers exist and at least one reaches the sea (a channel cell adjacent to
        // the ocean body).
        let half = n / 2;
        let mut river_cells = 0;
        let mut river_to_sea = 0;
        for gz in 0..n {
            for gx in 0..n {
                let wx = (gx - half) * OR_STEP;
                let wz = (gz - half) * OR_STEP;
                if river_channel_t(wx as f32, wz as f32, seed) > 0.4
                    && !is_ocean_column(wx as f32, wz as f32, seed)
                {
                    river_cells += 1;
                    for (dx, dz) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nx = gx + dx;
                        let nz = gz + dz;
                        if nx >= 0 && nz >= 0 && nx < n && nz < n && ocean[(nz * n + nx) as usize] == 0 {
                            river_to_sea += 1;
                        }
                    }
                }
            }
        }
        assert!(river_cells > 50, "too few river channel cells found ({river_cells})");
        assert!(
            river_to_sea > 0,
            "no river channel reaches the ocean (river_cells={river_cells})"
        );

        // DEPTH: the ocean must be a real, deep sea, not a sheet of shallow water.
        // The original "no real oceans" bug passed this test because it only checked
        // area (h <= SEA_LEVEL) and never depth: the limiter left the sea floor as a
        // field of near surface ridges, so the water was everywhere shallow. Guard
        // both the peak depth and that the deep core is coherently deep at FULL
        // resolution (not just at the coarse grid points, which can alias over the
        // bumps the bug produced).
        let mut max_depth = 0;
        let mut deep_cells = 0; // ocean grid cells deeper than 10 blocks
        let mut deepest = (0i32, 0i32, 0i32);
        for gz in 0..n {
            for gx in 0..n {
                if ocean[(gz * n + gx) as usize] == 0 {
                    let wx = (gx - half) * OR_STEP;
                    let wz = (gz - half) * OR_STEP;
                    let d = SEA_LEVEL - worldgen_surface_height(wx, wz, seed);
                    if d > max_depth {
                        max_depth = d;
                        deepest = (d, wx, wz);
                    }
                    if d >= 10 {
                        deep_cells += 1;
                    }
                }
            }
        }
        assert!(
            max_depth >= 16,
            "ocean too shallow: deepest point only {max_depth} blocks below sea level"
        );
        assert!(
            deep_cells >= 500,
            "too little deep sea: only {deep_cells} ocean cells deeper than 10 blocks"
        );
        // Full-resolution check of the deep core: scan a 64x64 window of blocks
        // around the deepest point and require the MINIMUM depth there to stay deep.
        // The bug left this minimum near zero (ridges poking to the surface); a real
        // basin keeps a deep floor across its core.
        let mut core_min = i32::MAX;
        for dz in -32..=32 {
            for dx in -32..=32 {
                let d = SEA_LEVEL - worldgen_surface_height(deepest.1 + dx, deepest.2 + dz, seed);
                if d < core_min {
                    core_min = d;
                }
            }
        }
        assert!(
            core_min >= 8,
            "ocean core is not coherently deep: a {}-block-deep point sits within the deep core (bumpy floor regression)",
            core_min
        );

        // The basin must actually be FILLED with water (not just low terrain): generate
        // the real chunk stack at the deepest column and count its WATER blocks. This
        // confirms the SEA_LEVEL fill reaches the deep floor, i.e. a real sea, not a dry
        // pit. Generate from the floor chunk up to the sea-surface chunk.
        let mut g = TerrainGen::new();
        g.seed(seed);
        let (dwx, dwz) = (deepest.1, deepest.2);
        let floor_h = worldgen_surface_height(dwx, dwz, seed);
        let cy_lo = (floor_h - 2).div_euclid(K_CHUNK_DIM);
        let cy_hi = SEA_LEVEL.div_euclid(K_CHUNK_DIM);
        let mut water_in_col = 0;
        for cy in cy_lo..=cy_hi {
            let cx = dwx.div_euclid(K_CHUNK_DIM);
            let cz = dwz.div_euclid(K_CHUNK_DIM);
            let mut chunk = DenseChunk::new(AIR);
            g.generate(ChunkCoord { x: cx, y: cy, z: cz }, &mut chunk);
            let lx = dwx.rem_euclid(K_CHUNK_DIM);
            let lz = dwz.rem_euclid(K_CHUNK_DIM);
            for ly in 0..K_CHUNK_DIM {
                if chunk.get(lx, ly, lz) == WATER {
                    water_in_col += 1;
                }
            }
        }
        assert!(
            water_in_col >= 12,
            "deepest ocean column holds only {water_in_col} water blocks; basin is not a filled deep sea"
        );
    }

    // -----------------------------------------------------------------------
    // Naked-trunk scan.
    //
    // Generates a dense voxel map across a sizable area (all 4 vertical
    // chunks), walks the tree cells exactly as the generator does, and for
    // every tall tree (trunk >= 4) reproduces its own canopy emission geometry
    // and measures how many of its intended leaf cells actually survived into
    // the world. A tree that kept less than a third of its own crown reads as
    // a naked trunk. Saplings and short deadwood stubs are not tall trees and
    // are excluded by the trunk >= 4 gate.
    // -----------------------------------------------------------------------
    use std::collections::HashMap;

    fn is_leaf(b: BlockId) -> bool {
        b == OAK_LEAVES || b == BIRCH_LEAVES || b == PINE_LEAVES
    }

    struct NakedTrunk {
        wx: i32,
        wz: i32,
        top_wy: i32,
        run: i32,
    }

    // Per-tree crown-retention record used by the distribution diagnostic.
    struct TreeRetention {
        wx: i32,
        wz: i32,
        intended: i32,
        filled: i32,
        forest: bool,
        // Bare trunk height: number of log blocks from trunk base up to the
        // lowest own leaf (the eye-level "wall of trunks" the player sees).
        bare_trunk: i32,
    }

    // Same world walk as scan_naked_trunks, but returns the full per-tree
    // retention distribution (own leaves kept vs intended) so we can measure
    // how thin crowns are and whether the thin ones cluster.
    fn scan_tree_retention(seed: u64, cx0: i32, cx1: i32, cz0: i32, cz1: i32) -> Vec<TreeRetention> {
        let mut g = TerrainGen::new();
        g.seed(seed);

        let mut voxels: HashMap<(i32, i32, i32), BlockId> = HashMap::new();
        for cz in cz0..=cz1 {
            for cx in cx0..=cx1 {
                for cy in 0..=3 {
                    let c = ChunkCoord { x: cx, y: cy, z: cz };
                    let mut chunk = DenseChunk::new(AIR);
                    g.generate(c, &mut chunk);
                    let bx = cx * K_CHUNK_DIM;
                    let by = cy * K_CHUNK_DIM;
                    let bz = cz * K_CHUNK_DIM;
                    for lz in 0..K_CHUNK_DIM {
                        for ly in 0..K_CHUNK_DIM {
                            for lx in 0..K_CHUNK_DIM {
                                let b = chunk.get(lx, ly, lz);
                                if b != AIR {
                                    voxels.insert((bx + lx, by + ly, bz + lz), b);
                                }
                            }
                        }
                    }
                }
            }
        }

        let get = |x: i32, y: i32, z: i32| -> BlockId { *voxels.get(&(x, y, z)).unwrap_or(&AIR) };

        let wx_lo = (cx0 + 1) * K_CHUNK_DIM;
        let wx_hi = cx1 * K_CHUNK_DIM - 1;
        let wz_lo = (cz0 + 1) * K_CHUNK_DIM;
        let wz_hi = cz1 * K_CHUNK_DIM - 1;

        let ccx0 = tree_floordiv(wx_lo, TREE_CELL_SIZE) - 1;
        let ccx1 = tree_floordiv(wx_hi, TREE_CELL_SIZE) + 1;
        let ccz0 = tree_floordiv(wz_lo, TREE_CELL_SIZE) - 1;
        let ccz1 = tree_floordiv(wz_hi, TREE_CELL_SIZE) + 1;

        let mut out = Vec::new();

        for ccz in ccz0..=ccz1 {
            for ccx in ccx0..=ccx1 {
                let td = tree_for_cell(ccx, ccz, seed);
                if !td.present {
                    continue;
                }
                let dom = voronoi_biome(td.root_wx, td.root_wz, seed);
                if dom == Biome::Desert || dom == Biome::Beach {
                    continue;
                }
                // Mirror the generator: a tree inside a structure's clearance
                // zone is never placed, so it cannot be judged here.
                if tree_blocked_by_structure(td.root_wx, td.root_wz, seed) {
                    continue;
                }
                let h = surface_height(td.root_wx, td.root_wz, seed);
                if h <= SEA_LEVEL {
                    continue;
                }
                let trunk_height = worldgen_trunk_fit_to_ceiling(h, canopy_dy_max(td.canopy_shape), td.trunk_height);
                if trunk_height <= 0 {
                    continue;
                }
                let trunk_top_wy = h + trunk_height;
                let canopy_wx = td.root_wx + td.lean_dx;
                let canopy_wz = td.root_wz + td.lean_dz;
                if canopy_wx < wx_lo || canopy_wx > wx_hi || canopy_wz < wz_lo || canopy_wz > wz_hi {
                    continue;
                }
                if trunk_height < 4 {
                    continue;
                }

                let dy_max_v = canopy_dy_max(td.canopy_shape);
                let dy_min_v = canopy_dy_min(td.canopy_shape) - td.extra_skirt;
                let shape_dy_min = canopy_dy_min(td.canopy_shape);
                let reach = if td.canopy_shape == CANOPY_GIANT {
                    4
                } else if td.canopy_shape == CANOPY_WEEPING {
                    4
                } else if td.canopy_shape == CANOPY_BROAD || td.canopy_shape == CANOPY_PINE {
                    3
                } else {
                    2
                };
                let mut intended = 0;
                let mut filled = 0;
                let mut lowest_leaf_wy = i32::MAX;
                for dz in -reach..=reach {
                    for dx in -reach..=reach {
                        for dy in dy_min_v..=dy_max_v {
                            let fill = if dy >= shape_dy_min {
                                in_canopy(dx, dy, dz, td.canopy_shape)
                            } else {
                                let ax = dx.abs();
                                let az = dz.abs();
                                (ax <= 3 && az <= 3) && (ax >= 2 || az >= 2) && !(ax == 3 && az == 3)
                            };
                            if !fill {
                                continue;
                            }
                            let wlx = canopy_wx + dx;
                            let wly = trunk_top_wy + dy;
                            let wlz = canopy_wz + dz;
                            if !keep_leaf_voxel(td.leaf_hash, td.sparse, wlx, wly, wlz, dx, dz) {
                                continue;
                            }
                            if dx == 0 && dz == 0 && wly <= trunk_top_wy {
                                continue;
                            }
                            intended += 1;
                            if is_leaf(get(wlx, wly, wlz)) {
                                filled += 1;
                                if wly < lowest_leaf_wy {
                                    lowest_leaf_wy = wly;
                                }
                            }
                        }
                    }
                }
                // Bare trunk = exposed logs from base up to the lowest leaf.
                let trunk_base_wy = h + 1;
                let bare_trunk = if lowest_leaf_wy == i32::MAX {
                    trunk_height
                } else {
                    (lowest_leaf_wy - trunk_base_wy).max(0)
                };
                if intended > 0 {
                    out.push(TreeRetention {
                        wx: canopy_wx,
                        wz: canopy_wz,
                        intended,
                        filled,
                        forest: dom == Biome::Forest,
                        bare_trunk,
                    });
                }
            }
        }
        out
    }

    // Diagnostic (ignored by default): locate a dense Forest region for the
    // test seed and print the per-tree crown-retention distribution, with a
    // clustering measure (how many thin crowns have a thin neighbour). Run with
    //   cargo test -- --ignored --nocapture forest_retention_distribution
    #[test]
    #[ignore]
    fn forest_retention_distribution() {
        // Find the chunk-region with the most Forest tree cells.
        let mut best = (0i32, 0i32, 0usize);
        let span = 6; // chunks per side of the scan window
        for cz0 in (-30..=30).step_by(6) {
            for cx0 in (-30..=30).step_by(6) {
                let recs = scan_tree_retention(SEED, cx0, cx0 + span, cz0, cz0 + span);
                let nf = recs.iter().filter(|r| r.forest).count();
                if nf > best.2 {
                    best = (cx0, cz0, nf);
                }
            }
        }
        let (cx0, cz0, _n) = best;
        let recs = scan_tree_retention(SEED, cx0, cx0 + span, cz0, cz0 + span);
        let forest: Vec<&TreeRetention> = recs.iter().filter(|r| r.forest).collect();
        let total = forest.len();
        let lt50: Vec<&&TreeRetention> = forest.iter().filter(|r| r.filled * 2 < r.intended).collect();
        let lt25: Vec<&&TreeRetention> = forest.iter().filter(|r| r.filled * 4 < r.intended).collect();
        let lt10: Vec<&&TreeRetention> = forest.iter().filter(|r| r.filled * 10 < r.intended).collect();

        // Clustering: of the <50% trees, how many have another <50% tree within
        // 10 blocks (one or two tree-cells away)?
        let mut clustered = 0;
        for a in &lt50 {
            for b in &lt50 {
                if std::ptr::eq(*a, *b) {
                    continue;
                }
                let d = (a.wx - b.wx).abs() + (a.wz - b.wz).abs();
                if d <= 10 {
                    clustered += 1;
                    break;
                }
            }
        }

        eprintln!("=== forest_retention_distribution seed {SEED} ===");
        eprintln!("dense forest window: chunks x[{cx0}..{}] z[{cz0}..{}]", cx0 + span, cz0 + span);
        eprintln!("forest tall trees: {total}");
        eprintln!("  < 50% crown: {} ({:.1}%)", lt50.len(), 100.0 * lt50.len() as f64 / total.max(1) as f64);
        eprintln!("  < 25% crown: {} ({:.1}%)", lt25.len(), 100.0 * lt25.len() as f64 / total.max(1) as f64);
        eprintln!("  < 10% crown: {} ({:.1}%)", lt10.len(), 100.0 * lt10.len() as f64 / total.max(1) as f64);
        eprintln!("  of the <50% trees, {clustered} have another <50% tree within 10 blocks");
        let avg: f64 = if total > 0 {
            forest.iter().map(|r| r.filled as f64 / r.intended as f64).sum::<f64>() / total as f64
        } else {
            0.0
        };
        eprintln!("  mean crown retention: {:.1}%", 100.0 * avg);

        // Absolute leafiness: how many trees have a near-bare crown in raw
        // leaf-cell terms, regardless of "intended" (which bakes in the same
        // sparse nibble and so can hide over-thinning).
        let mut lt8 = 0; // fewer than 8 own leaf cells
        let mut lt4 = 0; // fewer than 4 own leaf cells
        let mut intsum = 0;
        let mut fillsum = 0;
        for r in &forest {
            if r.filled < 8 {
                lt8 += 1;
            }
            if r.filled < 4 {
                lt4 += 1;
            }
            intsum += r.intended;
            fillsum += r.filled;
        }
        eprintln!("  trees with < 8 own leaf cells: {lt8}");
        eprintln!("  trees with < 4 own leaf cells: {lt4}");
        eprintln!("  mean intended leaves/tree: {:.1}", intsum as f64 / total.max(1) as f64);
        eprintln!("  mean filled   leaves/tree: {:.1}", fillsum as f64 / total.max(1) as f64);

        // Bare-trunk (eye-level wall) distribution.
        let mut bsum = 0;
        let mut bmax = 0;
        let mut ge6 = 0;
        for r in &forest {
            bsum += r.bare_trunk;
            if r.bare_trunk > bmax {
                bmax = r.bare_trunk;
            }
            if r.bare_trunk >= 6 {
                ge6 += 1;
            }
        }
        eprintln!("  mean bare-trunk height (base to lowest leaf): {:.1}", bsum as f64 / total.max(1) as f64);
        eprintln!("  max bare-trunk height: {bmax}");
        eprintln!("  trees with >= 6 bare log blocks: {ge6} ({:.1}%)", 100.0 * ge6 as f64 / total.max(1) as f64);

        roof_coverage(SEED, cx0, cx0 + span, cz0, cz0 + span);
    }

    // Measure, over a window, how much of the ground is under a leaf roof and
    // the exposed-trunk picture: for each surface column inside a forest, is
    // there a leaf above it, and how many bare log cells are exposed to the sky.
    fn roof_coverage(seed: u64, cx0: i32, cx1: i32, cz0: i32, cz1: i32) {
        let mut g = TerrainGen::new();
        g.seed(seed);
        let mut top_leaf: HashMap<(i32, i32), i32> = HashMap::new();
        let mut top_log: HashMap<(i32, i32), i32> = HashMap::new();
        let mut has_tree_col: std::collections::HashSet<(i32, i32)> = std::collections::HashSet::new();
        for cz in cz0..=cz1 {
            for cx in cx0..=cx1 {
                for cy in 0..=3 {
                    let c = ChunkCoord { x: cx, y: cy, z: cz };
                    let mut chunk = DenseChunk::new(AIR);
                    g.generate(c, &mut chunk);
                    let bx = cx * K_CHUNK_DIM;
                    let by = cy * K_CHUNK_DIM;
                    let bz = cz * K_CHUNK_DIM;
                    for lz in 0..K_CHUNK_DIM {
                        for lx in 0..K_CHUNK_DIM {
                            let key = (bx + lx, bz + lz);
                            for ly in 0..K_CHUNK_DIM {
                                let b = chunk.get(lx, ly, lz);
                                let wy = by + ly;
                                if is_leaf(b) {
                                    let e = top_leaf.entry(key).or_insert(i32::MIN);
                                    if wy > *e {
                                        *e = wy;
                                    }
                                    has_tree_col.insert(key);
                                }
                                if b == OAK_LOG || b == BIRCH_LOG || b == PINE_LOG {
                                    let e = top_log.entry(key).or_insert(i32::MIN);
                                    if wy > *e {
                                        *e = wy;
                                    }
                                    has_tree_col.insert(key);
                                }
                            }
                        }
                    }
                }
            }
        }
        // Of the columns that contain any tree material, how many have a leaf as
        // the topmost tree block (leafy) vs a log poking above all leaves (bare)?
        let mut leafy_top = 0;
        let mut log_top = 0;
        for key in &has_tree_col {
            let tl = top_leaf.get(key).copied().unwrap_or(i32::MIN);
            let tg = top_log.get(key).copied().unwrap_or(i32::MIN);
            if tg > tl {
                log_top += 1;
            } else if tl > i32::MIN {
                leafy_top += 1;
            }
        }
        let denom = (leafy_top + log_top).max(1);
        eprintln!("  --- roof picture ---");
        eprintln!("  tree columns: {}", has_tree_col.len());
        eprintln!("  columns whose TOP tree block is a leaf: {leafy_top}");
        eprintln!("  columns whose TOP tree block is a LOG (bare tip to sky): {log_top} ({:.1}%)",
            100.0 * log_top as f64 / denom as f64);
    }

    // Multi-seed sweep: worst forest window per seed, reporting bare-trunk
    // fraction and crown retention, to see if the symptom is seed-specific.
    #[test]
    #[ignore]
    fn forest_sweep_seeds() {
        for seed in [11u64, 1, 2, 7, 42, 1234, 99999] {
            let span = 6;
            let mut best = (0i32, 0i32, 0usize);
            for cz0 in (-40..=40).step_by(8) {
                for cx0 in (-40..=40).step_by(8) {
                    let recs = scan_tree_retention(seed, cx0, cx0 + span, cz0, cz0 + span);
                    let nf = recs.iter().filter(|r| r.forest).count();
                    if nf > best.2 {
                        best = (cx0, cz0, nf);
                    }
                }
            }
            let (cx0, cz0, nf) = best;
            let recs = scan_tree_retention(seed, cx0, cx0 + span, cz0, cz0 + span);
            let forest: Vec<&TreeRetention> = recs.iter().filter(|r| r.forest).collect();
            let total = forest.len().max(1);
            let lt50 = forest.iter().filter(|r| r.filled * 2 < r.intended).count();
            let avg: f64 = forest.iter().map(|r| r.filled as f64 / r.intended as f64).sum::<f64>() / total as f64;
            eprintln!("seed {seed:>6}: forest trees {nf:>4} (window x{cx0} z{cz0}), <50% crown {lt50}, mean retention {:.1}%", 100.0 * avg);
            roof_coverage(seed, cx0, cx0 + span, cz0, cz0 + span);
        }
    }

    // Build the world over chunk range [cx0,cx1] x [cz0,cz1], all y chunks
    // 0..=3 (y 0..63), into a flat voxel map, and return all tall naked
    // trunks plus the total tree-log column count for context.
    fn scan_naked_trunks(seed: u64, cx0: i32, cx1: i32, cz0: i32, cz1: i32) -> (Vec<NakedTrunk>, usize) {
        let mut g = TerrainGen::new();
        g.seed(seed);

        let mut voxels: HashMap<(i32, i32, i32), BlockId> = HashMap::new();
        for cz in cz0..=cz1 {
            for cx in cx0..=cx1 {
                for cy in 0..=3 {
                    let c = ChunkCoord { x: cx, y: cy, z: cz };
                    let mut chunk = DenseChunk::new(AIR);
                    g.generate(c, &mut chunk);
                    let bx = cx * K_CHUNK_DIM;
                    let by = cy * K_CHUNK_DIM;
                    let bz = cz * K_CHUNK_DIM;
                    for lz in 0..K_CHUNK_DIM {
                        for ly in 0..K_CHUNK_DIM {
                            for lx in 0..K_CHUNK_DIM {
                                let b = chunk.get(lx, ly, lz);
                                if b != AIR {
                                    voxels.insert((bx + lx, by + ly, bz + lz), b);
                                }
                            }
                        }
                    }
                }
            }
        }

        let get = |x: i32, y: i32, z: i32| -> BlockId { *voxels.get(&(x, y, z)).unwrap_or(&AIR) };

        // Walk the tree cells the same way the generator does, reproduce each
        // tree's geometry, and for the trees whose crown lands in the inner
        // area, check whether the crown actually has leaves. A trunk is
        // "naked" when its top log run has no leaf at or above the trunk top
        // anywhere in its own canopy footprint, i.e. the bare trunk pokes out.
        let wx_lo = (cx0 + 1) * K_CHUNK_DIM;
        let wx_hi = cx1 * K_CHUNK_DIM - 1;
        let wz_lo = (cz0 + 1) * K_CHUNK_DIM;
        let wz_hi = cz1 * K_CHUNK_DIM - 1;

        let ccx0 = tree_floordiv(wx_lo, TREE_CELL_SIZE) - 1;
        let ccx1 = tree_floordiv(wx_hi, TREE_CELL_SIZE) + 1;
        let ccz0 = tree_floordiv(wz_lo, TREE_CELL_SIZE) - 1;
        let ccz1 = tree_floordiv(wz_hi, TREE_CELL_SIZE) + 1;

        let mut total_trunk_cols = 0usize;
        let mut naked = Vec::new();

        for ccz in ccz0..=ccz1 {
            for ccx in ccx0..=ccx1 {
                let td = tree_for_cell(ccx, ccz, seed);
                if !td.present {
                    continue;
                }
                let dom = voronoi_biome(td.root_wx, td.root_wz, seed);
                if dom == Biome::Desert || dom == Biome::Beach {
                    continue;
                }
                // Mirror the generator: a tree inside a structure's clearance
                // zone is never placed at all. Judging it here would count a
                // legitimately suppressed tree as a "naked trunk" false
                // positive (its intended crown has zero surviving leaves
                // because the whole tree does not exist).
                if tree_blocked_by_structure(td.root_wx, td.root_wz, seed) {
                    continue;
                }
                let h = surface_height(td.root_wx, td.root_wz, seed);
                if h <= SEA_LEVEL {
                    continue;
                }
                let trunk_height = worldgen_trunk_fit_to_ceiling(h, canopy_dy_max(td.canopy_shape), td.trunk_height);
                if trunk_height <= 0 {
                    continue;
                }
                let trunk_top_wy = h + trunk_height;
                let canopy_wx = td.root_wx + td.lean_dx;
                let canopy_wz = td.root_wz + td.lean_dz;

                // Only consider trees whose crown sits inside the inner area
                // (so its full canopy and all neighbours are generated).
                if canopy_wx < wx_lo || canopy_wx > wx_hi || canopy_wz < wz_lo || canopy_wz > wz_hi {
                    continue;
                }

                // Only tall trees; short stubs/saplings are not the bug.
                if trunk_height < 4 {
                    continue;
                }
                total_trunk_cols += 1;

                // Recreate this tree's OWN intended leaf cells using the exact
                // emission geometry (shape, reach, sparse nibble), then check
                // how many of those cells actually hold a leaf in the dense
                // world. A cell that holds a log/other block was eaten by a
                // neighbour (or this tree's own trunk). A tree whose own crown
                // is mostly eaten reads as a naked trunk.
                let dy_max_v = canopy_dy_max(td.canopy_shape);
                let dy_min_v = canopy_dy_min(td.canopy_shape) - td.extra_skirt;
                let shape_dy_min = canopy_dy_min(td.canopy_shape);
                let reach = if td.canopy_shape == CANOPY_GIANT {
                    4
                } else if td.canopy_shape == CANOPY_WEEPING {
                    4
                } else if td.canopy_shape == CANOPY_BROAD || td.canopy_shape == CANOPY_PINE {
                    3
                } else {
                    2
                };
                let mut intended = 0;
                let mut filled = 0;
                for dz in -reach..=reach {
                    for dx in -reach..=reach {
                        for dy in dy_min_v..=dy_max_v {
                            let fill = if dy >= shape_dy_min {
                                in_canopy(dx, dy, dz, td.canopy_shape)
                            } else {
                                let ax = dx.abs();
                                let az = dz.abs();
                                (ax <= 3 && az <= 3) && (ax >= 2 || az >= 2) && !(ax == 3 && az == 3)
                            };
                            if !fill {
                                continue;
                            }
                            let wlx = canopy_wx + dx;
                            let wly = trunk_top_wy + dy;
                            let wlz = canopy_wz + dz;
                            if !keep_leaf_voxel(td.leaf_hash, td.sparse, wlx, wly, wlz, dx, dz) {
                                continue;
                            }
                            // Skip the trunk cell (own log occupies it).
                            if dx == 0 && dz == 0 && wly <= trunk_top_wy {
                                continue;
                            }
                            intended += 1;
                            if is_leaf(get(wlx, wly, wlz)) {
                                filled += 1;
                            }
                        }
                    }
                }

                // Naked: less than 1/3 of this tree's own intended leaf cells
                // actually became leaves (the crown was eaten by neighbours).
                if intended > 0 && (filled * 3) < intended {
                    naked.push(NakedTrunk { wx: canopy_wx, wz: canopy_wz, top_wy: trunk_top_wy, run: trunk_height });
                }
            }
        }

        (naked, total_trunk_cols)
    }

    // Symmetric to canopy_dy_max_covers_true_top: every shape's emission FLOOR
    // (canopy_dy_min) must reach as low as in_canopy actually fills, or that
    // bottom leaf layer is never iterated and the crown is clipped at the
    // bottom, raising the leaf line one block up the trunk. That extra bare log
    // per tree is what reads as a wall of bare trunks in a dense wood. The bug:
    // ROUND/BROAD/COMPACT/GIANT all fill down to dy=-2 but canopy_dy_min
    // returned -1, dropping the whole bottom dome layer.
    #[test]
    fn canopy_dy_min_covers_true_bottom() {
        let shapes = [
            CANOPY_ROUND,
            CANOPY_TALL,
            CANOPY_BROAD,
            CANOPY_COMPACT,
            CANOPY_PINE,
            CANOPY_GIANT,
            CANOPY_WEEPING,
            CANOPY_FORKED,
        ];
        for shape in shapes {
            let mut true_bot = i32::MAX;
            for dy in -5..=6 {
                for dz in -5..=5 {
                    for dx in -5..=5 {
                        if in_canopy(dx, dy, dz, shape) && dy < true_bot {
                            true_bot = dy;
                        }
                    }
                }
            }
            assert!(
                canopy_dy_min(shape) <= true_bot,
                "shape {shape}: canopy_dy_min {} > true bottom dy {true_bot} (bottom crown layer would be dropped)",
                canopy_dy_min(shape)
            );
        }
    }

    // Regression: a DENSE forest must read as leafy at eye level, not as a wall
    // of bare trunks. Crowns can be 100% intact (see no_tall_naked_trunks) yet
    // the wood still looks bare if every canopy is a thin cap on a long pole. We
    // locate the densest Forest window for the seed and require the average bare
    // trunk (base up to the lowest own leaf) to stay low and few trees to be
    // long bare poles. Guards both the canopy_dy_min bottom-clip and the trunk
    // skirt that fills the lower trunk with leaves.
    #[test]
    fn dense_forest_is_leafy() {
        let span = 6;
        let mut best = (0i32, 0i32, 0usize);
        for cz0 in (-30..=30).step_by(6) {
            for cx0 in (-30..=30).step_by(6) {
                let recs = scan_tree_retention(SEED, cx0, cx0 + span, cz0, cz0 + span);
                let nf = recs.iter().filter(|r| r.forest).count();
                if nf > best.2 {
                    best = (cx0, cz0, nf);
                }
            }
        }
        let (cx0, cz0, nf) = best;
        assert!(nf > 60, "no dense forest window found (best {nf} trees)");
        let recs = scan_tree_retention(SEED, cx0, cx0 + span, cz0, cz0 + span);
        let forest: Vec<&TreeRetention> = recs.iter().filter(|r| r.forest).collect();
        let total = forest.len();

        let bare_sum: i32 = forest.iter().map(|r| r.bare_trunk).sum();
        let mean_bare = bare_sum as f64 / total as f64;
        let long_poles = forest.iter().filter(|r| r.bare_trunk >= 6).count();
        let pole_frac = long_poles as f64 / total as f64;

        // Before the fix this window had mean ~6.2 and ~62% long poles; after,
        // ~3.9 and ~9%. Guard with comfortable margins so tuning has headroom
        // but a regression to the old bare-pole wood fails loudly.
        assert!(
            mean_bare <= 4.8,
            "dense forest bare-trunk wall: mean bare trunk {mean_bare:.1} blocks over {total} trees (want <= 4.8)"
        );
        assert!(
            pole_frac <= 0.25,
            "dense forest bare-trunk wall: {:.0}% of trees are long bare poles (>=6 bare logs), want <= 25%",
            100.0 * pole_frac
        );
    }

    // Every canopy shape's emission ceiling (canopy_dy_max) must cover the
    // highest dy that in_canopy actually fills. If it does not, the top leaf
    // layer is never iterated in place_decorations and the crown is capped
    // short, leaving a bald trunk tip. This was the residual naked-trunk bug:
    // ROUND/BROAD reached dy=2 and GIANT reached dy=3, but canopy_dy_max
    // returned 1, so 9/5/26 top cells per crown were silently dropped.
    #[test]
    fn canopy_dy_max_covers_true_top() {
        let shapes = [
            CANOPY_ROUND,
            CANOPY_TALL,
            CANOPY_BROAD,
            CANOPY_COMPACT,
            CANOPY_PINE,
            CANOPY_GIANT,
            CANOPY_WEEPING,
            CANOPY_FORKED,
        ];
        for shape in shapes {
            let mut true_top = i32::MIN;
            for dy in -4..=6 {
                for dz in -5..=5 {
                    for dx in -5..=5 {
                        if in_canopy(dx, dy, dz, shape) && dy > true_top {
                            true_top = dy;
                        }
                    }
                }
            }
            assert!(
                canopy_dy_max(shape) >= true_top,
                "shape {shape}: canopy_dy_max {} < true top dy {true_top} (top crown layer would be dropped)",
                canopy_dy_max(shape)
            );
        }
    }

    // Regression: no tall tree (trunk >= 4) may end up with its own crown
    // mostly eaten in a dense forest. We reproduce each tree's exact emission
    // geometry and require at least a third of its intended leaf cells to
    // survive into the generated world. A bare trunk poking out of a dense
    // wood is the symptom we are guarding against.
    #[test]
    fn no_tall_naked_trunks() {
        // #: real oceans pushed much of the origin region underwater for some
        // seeds, so trees (which only grow above sea level) are sparse in a tight
        // window. Scan a wider area so the sample still contains plenty of forested
        // land (widened again for #168: the smooth-gradation terrain nudged tree
        // sites and left 96 tall trees in the old window). The naked-trunk
        // invariant is unchanged.
        let (naked, total) = scan_naked_trunks(SEED, -26, 26, -26, 26);
        assert!(total > 100, "scan saw too few tall trees ({total}) to be meaningful");
        assert!(
            naked.is_empty(),
            "found {} tall naked trunks (e.g. wx={} wz={} top_wy={} trunk={})",
            naked.len(),
            naked.first().map(|n| n.wx).unwrap_or(0),
            naked.first().map(|n| n.wz).unwrap_or(0),
            naked.first().map(|n| n.top_wy).unwrap_or(0),
            naked.first().map(|n| n.run).unwrap_or(0),
        );
    }

    // #142: a torch placed by a structure builder must be MOUNTED on a wall, not
    // recessed into it. Two invariants per torch cell, checked over every keep and
    // cabin found in a wide scan:
    //   1. The torch cell itself is the only non-solid thing there (a torch reads as
    //      a prop in an air-adjacent cell), and
    //   2. it has at least one solid horizontal neighbour (the wall it is mounted on),
    //      AND no wall block was removed to make room for it: specifically the cell
    //      the torch used to occupy in the old recessed placement stays solid wall.
    // We check the structural invariant directly: every torch must sit beside a solid
    // wall block (so it is mounted) and must not itself be embedded inside a ring of
    // solid blocks (which would mean a hole was carved around it).
    #[test]
    fn structure_torches_mounted_on_solid_wall() {
        // A block id that counts as a solid wall face a torch can mount on.
        fn is_solid_wall(b: BlockId) -> bool {
            b != AIR
                && b != TORCH
                && b != OAK_DOOR
                && b != GLASS_PANE
                && b != WATER
                && b != MARKER_BLOCK
        }

        let mut keeps_checked = 0;
        let mut cabins_checked = 0;
        let mut torches_checked = 0;

        // Stamping a structure is expensive, so cap how many of each type we stamp;
        // a handful per type across several seeds is plenty to guard the invariant.
        let cap = 6;
        'seeds: for &seed in &[11u64, 1, 42, 7, 1234] {
            let r = 40; // structure cells; wide enough to catch keeps and cabins
            for scz in -r..=r {
                for scx in -r..=r {
                    let sd = struct_for_cell(scx, scz, seed);
                    if !sd.present {
                        continue;
                    }
                    let is_keep = sd.typ == STRUCT_KEEP;
                    let is_cabin = sd.typ == STRUCT_CABIN;
                    if !is_keep && !is_cabin {
                        continue;
                    }
                    if is_keep && keeps_checked >= cap {
                        continue;
                    }
                    if is_cabin && cabins_checked >= cap {
                        continue;
                    }
                    if is_keep {
                        keeps_checked += 1;
                    } else {
                        cabins_checked += 1;
                    }

                    let cells = stamp_structure(&sd, seed);
                    for (&(wx, wy, wz), &b) in cells.iter() {
                        if b != TORCH {
                            continue;
                        }
                        torches_checked += 1;

                        // Mounted: at least one horizontal neighbour is a solid wall.
                        let neigh = [
                            *cells.get(&(wx + 1, wy, wz)).unwrap_or(&AIR),
                            *cells.get(&(wx - 1, wy, wz)).unwrap_or(&AIR),
                            *cells.get(&(wx, wy, wz + 1)).unwrap_or(&AIR),
                            *cells.get(&(wx, wy, wz - 1)).unwrap_or(&AIR),
                        ];
                        let solid_neighbours = neigh.iter().filter(|&&n| is_solid_wall(n)).count();
                        assert!(
                            solid_neighbours >= 1,
                            "seed {seed} type {}: torch at ({wx},{wy},{wz}) is not mounted on any wall (neighbours {neigh:?})",
                            sd.typ
                        );
                        // Not recessed: the torch is in an air-adjacent cell, so it must
                        // NOT be boxed in on all four horizontal sides (a hole carved
                        // into a wall would leave solid faces all around the recess).
                        assert!(
                            solid_neighbours < 4,
                            "seed {seed} type {}: torch at ({wx},{wy},{wz}) is boxed in on all sides, looks recessed into the wall",
                            sd.typ
                        );
                    }
                    if keeps_checked >= cap && cabins_checked >= cap {
                        break 'seeds;
                    }
                }
            }
        }

        assert!(keeps_checked > 0, "scan found no keeps to check");
        assert!(cabins_checked > 0, "scan found no cabins to check");
        assert!(torches_checked > 0, "scan found no torches to check");
    }

    // #148 / #149: every structure doorway must be a single 2-block-tall door opening
    // with a SOLID lintel directly above it and solid wall flanking the jambs. The two
    // bugs this guards:
    //   #148: a doorway that reads as two separate 1-tall doors (a lone 1-tall door, or
    //         a stack taller / shorter than 2, or two doors side by side).
    //   #149: a gap over the doorway (the cell directly above the 2-tall door left open
    //         instead of a solid lintel block).
    // We stamp a capped sample of cabins / keeps / towers from a wide scan, group the
    // door cells into vertical runs per (wx, wz) column, and assert each run is exactly
    // 2 tall, has a solid block right above, solid wall on both jamb sides along the
    // run, and no door block as a horizontal neighbour (no side-by-side double door).
    #[test]
    fn structure_doors_are_single_2tall_with_solid_lintel() {
        // A block that counts as a solid wall / lintel (not air, not the door, not a
        // see-through pane or prop).
        fn is_solid(b: BlockId) -> bool {
            b != AIR
                && b != OAK_DOOR
                && b != TORCH
                && b != GLASS_PANE
                && b != WATER
                && b != MARKER_BLOCK
        }

        let mut doorways_checked = 0;
        // Sample cells are pinned per seed; the structure type roll depends on
        // the biome, so a biome-scale change (#172) can reroll a pinned cell.
        // These cells were re-picked for the #172 constants.
        // Re-picked for the #179 looping-world constants (canonical-frame cells).
        let samples = [
            (11u64, 17, 0, STRUCT_CABIN),
            (11u64, 45, 0, STRUCT_KEEP),
            (11u64, 61, 0, STRUCT_TALL_TOWER),
        ];

        for &(seed, scx, scz, expected_typ) in &samples {
            let sd = struct_for_cell(scx, scz, seed);
            assert!(
                sd.present,
                "door regression sample missing: seed {seed} cell ({scx},{scz})"
            );
            assert_eq!(
                sd.typ, expected_typ,
                "door regression sample type changed: seed {seed} cell ({scx},{scz})"
            );

            let cells = stamp_structure(&sd, seed);

            // Collect every door cell, grouped by (wx, wz) column.
            let mut columns: std::collections::HashMap<(i32, i32), Vec<i32>> =
                std::collections::HashMap::new();
            for (&(wx, wy, wz), &b) in cells.iter() {
                if b == OAK_DOOR {
                    columns.entry((wx, wz)).or_default().push(wy);
                }
            }
            if columns.is_empty() {
                continue;
            }

            for ((wx, wz), mut ys) in columns {
                ys.sort_unstable();

                // A single column of door blocks must be exactly 2 tall and
                // contiguous: a lone 1-tall door, or any run != 2, reads as a
                // broken / doubled door (#148).
                assert_eq!(
                    ys.len(),
                    2,
                    "seed {seed} type {}: door column at ({wx},{wz}) has {} door blocks (ys={ys:?}), expected exactly 2 (single 2-tall door)",
                    sd.typ,
                    ys.len()
                );
                let (low, high) = (ys[0], ys[1]);
                assert_eq!(
                    high,
                    low + 1,
                    "seed {seed} type {}: door column at ({wx},{wz}) is not two contiguous cells (ys={ys:?})",
                    sd.typ
                );

                // #149: the cell directly above the door run is a solid lintel.
                let above = *cells.get(&(wx, high + 1, wz)).unwrap_or(&AIR);
                assert!(
                    is_solid(above),
                    "seed {seed} type {}: gap over doorway at ({wx},{wz}) y={} (block above = {above}); lintel must be solid wall",
                    sd.typ,
                    high + 1
                );

                // No door block as a horizontal neighbour of either door cell:
                // rules out two doorways placed side by side (#148).
                for &dy in &[low, high] {
                    for (nx, nz) in [(wx + 1, wz), (wx - 1, wz), (wx, wz + 1), (wx, wz - 1)] {
                        let nb = *cells.get(&(nx, dy, nz)).unwrap_or(&AIR);
                        assert!(
                            nb != OAK_DOOR,
                            "seed {seed} type {}: door cell at ({wx},{dy},{wz}) has an adjacent door at ({nx},{dy},{nz}); reads as two side-by-side doors",
                            sd.typ
                        );
                    }
                }

                // The doorway is flanked by closed wall jambs. The wall the door
                // sits in runs along one horizontal axis; whichever axis it is,
                // both cells flanking the door along that axis must be filled (a
                // solid wall block or a glass window pane, never air and never
                // another door) at both door heights. Requiring a closed jamb on
                // BOTH sides of one axis forbids an opening wider than the single
                // door (#148). A glass pane beside the door is a normal window, so
                // it counts as a closed jamb here.
                let jamb_filled = |b: BlockId| b != AIR && b != OAK_DOOR;
                let jamb_solid_axis = |a: [(i32, i32); 2]| -> bool {
                    a.iter().all(|&(jx, jz)| {
                        jamb_filled(*cells.get(&(jx, low, jz)).unwrap_or(&AIR))
                            && jamb_filled(*cells.get(&(jx, high, jz)).unwrap_or(&AIR))
                    })
                };
                let x_axis = [(wx + 1, wz), (wx - 1, wz)];
                let z_axis = [(wx, wz + 1), (wx, wz - 1)];
                assert!(
                    jamb_solid_axis(x_axis) || jamb_solid_axis(z_axis),
                    "seed {seed} type {}: doorway at ({wx},{wz}) is not flanked by solid wall on either axis (opening too wide / no jambs)",
                    sd.typ
                );

                doorways_checked += 1;
            }
        }

        assert!(doorways_checked > 0, "scan found no doorways to check");
    }

    // #142 (regression, exact geometry): after the fix, the wall blocks that used to
    // be punched out for a recessed torch must stay solid. For a cabin the wall behind
    // its torch must be solid; for a keep the curtain-wall sections that flank the
    // gate must be solid at the torch height (no hole punched behind a gate torch).
    #[test]
    fn structure_torch_walls_stay_solid() {
        let mut checked_cabin = false;
        let mut checked_keep = false;

        for &seed in &[11u64, 1, 42, 7, 1234] {
            let r = 40;
            for scz in -r..=r {
                for scx in -r..=r {
                    let sd = struct_for_cell(scx, scz, seed);
                    if !sd.present {
                        continue;
                    }
                    if sd.typ == STRUCT_CABIN && !checked_cabin {
                        let cells = stamp_structure(&sd, seed);
                        // Locate the cabin's single torch and assert the wall cell
                        // directly behind it (toward the door wall plane) is solid: the
                        // torch must be mounted on an intact wall, never carved into one.
                        let mut found_torch = false;
                        for (&(wx, wy, wz), &b) in cells.iter() {
                            if b != TORCH {
                                continue;
                            }
                            found_torch = true;
                            // The wall the torch mounts on is one of its 4 horizontal
                            // neighbours; at least one must be a solid (non-air, non-prop)
                            // block, and the torch must not sit where a wall block was.
                            let neigh = [
                                *cells.get(&(wx + 1, wy, wz)).unwrap_or(&AIR),
                                *cells.get(&(wx - 1, wy, wz)).unwrap_or(&AIR),
                                *cells.get(&(wx, wy, wz + 1)).unwrap_or(&AIR),
                                *cells.get(&(wx, wy, wz - 1)).unwrap_or(&AIR),
                            ];
                            let solid = |bb: BlockId| {
                                bb != AIR && bb != TORCH && bb != OAK_DOOR && bb != GLASS_PANE
                            };
                            assert!(
                                neigh.iter().any(|&n| solid(n)),
                                "seed {seed}: cabin torch at ({wx},{wy},{wz}) has no solid wall behind it (neighbours {neigh:?})"
                            );
                        }
                        assert!(found_torch, "seed {seed}: cabin had no torch to check");
                        checked_cabin = true;
                    }

                    if sd.typ == STRUCT_KEEP && !checked_keep {
                        let cells = stamp_structure(&sd, seed);
                        let h = sd.cell_hash;
                        let mut base_h = -1000000;
                        for dz in -4..=4 {
                            for dx in -4..=4 {
                                let sh = struct_surface(sd.anchor_wx + dx, sd.anchor_wz + dz, seed);
                                if sh > base_h {
                                    base_h = sh;
                                }
                            }
                        }
                        let _ = h;
                        let rr = 4;
                        // Curtain wall sections flanking the 2 wide gate (gate spans
                        // dx in {0,-1}); dx = +1 and dx = -2 at dz = -r must be solid
                        // at the torch height (base_h + 3), with no hole behind a torch.
                        for &gdx in &[1i32, -2] {
                            let wall = *cells
                                .get(&(sd.anchor_wx + gdx, base_h + 3, sd.anchor_wz - rr))
                                .unwrap_or(&AIR);
                            assert!(
                                wall != AIR && wall != TORCH,
                                "seed {seed}: keep gate wall at dx={gdx} is not solid (got {wall}); torch carved a hole in the curtain wall"
                            );
                        }
                        checked_keep = true;
                    }
                }
            }
        }

        assert!(checked_cabin, "no cabin found to check torch wall solidity");
        assert!(checked_keep, "no keep found to check torch wall solidity");
    }

    // #143: trees must not be emitted inside the no-tree clearance zone around a
    // structure footprint, so trunks / canopies never intersect a building. Find real
    // structures in a wide scan and assert that no tree cell whose root falls within
    // (footprint reach + clearance) of the anchor is reported present-and-buildable
    // by the same gate the decoration pass uses.
    #[test]
    fn no_trees_inside_structure_clearance() {
        let mut structures_checked = 0;
        let mut roots_inside_zone = 0;

        for &seed in &[11u64, 1, 42, 7, 1234] {
            let r = 30;
            for scz in -r..=r {
                for scx in -r..=r {
                    let sd = struct_for_cell(scx, scz, seed);
                    if !sd.present || sd.typ == STRUCT_NONE {
                        continue;
                    }
                    structures_checked += 1;
                    let clear = struct_footprint_reach(sd.typ) + STRUCT_TREE_CLEARANCE;
                    // Sweep every tree cell whose cell window overlaps the clearance box.
                    let (cx0, cz0) = tree_cell(sd.anchor_wx - clear, sd.anchor_wz - clear);
                    let (cx1, cz1) = tree_cell(sd.anchor_wx + clear, sd.anchor_wz + clear);
                    for ccz in cz0..=cz1 {
                        for ccx in cx0..=cx1 {
                            let td = tree_for_cell(ccx, ccz, seed);
                            if !td.present {
                                continue;
                            }
                            // A tree only ever reaches the world if it survives the same
                            // gate the decoration pass applies (biome / sea level), AND
                            // it must NOT survive the structure-clearance gate when its
                            // root is inside the zone.
                            let dx = (td.root_wx - sd.anchor_wx).abs();
                            let dz = (td.root_wz - sd.anchor_wz).abs();
                            if dx <= clear && dz <= clear {
                                roots_inside_zone += 1;
                                assert!(
                                    tree_blocked_by_structure(td.root_wx, td.root_wz, seed),
                                    "seed {seed}: tree root ({},{}) is inside the clearance of structure type {} at ({},{}) but was not blocked",
                                    td.root_wx,
                                    td.root_wz,
                                    sd.typ,
                                    sd.anchor_wx,
                                    sd.anchor_wz
                                );
                            }
                        }
                    }
                }
            }
        }

        assert!(structures_checked > 0, "scan found no structures to check");
        assert!(
            roots_inside_zone > 0,
            "scan found no candidate tree roots inside any clearance zone (test would be vacuous)"
        );
    }

    // Diagnostic visual: dump real generated structure cross-sections (torch / wall
    // glyphs) and a top-down tree map around a structure, straight from the
    // generator. Run with: cargo test --release dump_structure_diag -- --nocapture
    // --ignored. Not part of the gate (ignored); it is the visual artifact for the
    // #142 / #143 fixes since the headless --shot harness cannot teleport to a
    // structure.
    #[test]
    #[ignore]
    fn dump_structure_diag() {
        fn glyph(b: BlockId) -> char {
            match b {
                AIR => '.',
                TORCH => 'T',
                OAK_DOOR => 'D',
                GLASS_PANE => 'o',
                GLOW_BLOCK => '*',
                _ => '#', // any solid wall / floor / roof block
            }
        }

        // Find and dump one keep and one cabin: a vertical Z slice through each
        // torch so you can see the torch (T) sitting in air with an intact wall (#)
        // directly behind it.
        for &want in &[STRUCT_KEEP, STRUCT_CABIN] {
            'find: for &seed in &[11u64, 1, 42, 7, 1234] {
                let r = 40;
                for scz in -r..=r {
                    for scx in -r..=r {
                        let sd = struct_for_cell(scx, scz, seed);
                        if !sd.present || sd.typ != want {
                            continue;
                        }
                        let cells = stamp_structure(&sd, seed);
                        // For each torch, print a small X-by-Y slice at the torch's Z.
                        let torches: Vec<(i32, i32, i32)> = cells
                            .iter()
                            .filter(|(_, &b)| b == TORCH)
                            .map(|(&(x, y, z), _)| (x, y, z))
                            .collect();
                        println!(
                            "\n=== structure type {} seed {seed} anchor ({},{}) : {} torch(es) ===",
                            sd.typ, sd.anchor_wx, sd.anchor_wz, torches.len()
                        );
                        for (tx, ty, tz) in &torches {
                            // Slice through the torch's Z (shows the torch in air).
                            println!("-- X/Y slice at z={tz} (torch at {tx},{ty},{tz}); T=torch #=wall .=air --");
                            for wy in (ty - 3..=ty + 3).rev() {
                                let mut line = String::new();
                                for wx in (tx - 4)..=(tx + 4) {
                                    let b = *cells.get(&(wx, wy, *tz)).unwrap_or(&AIR);
                                    line.push(glyph(b));
                                }
                                println!("  y={wy:>4} {line}");
                            }
                            // Slice one cell toward the wall the torch backs onto: this
                            // is the wall plane that must stay SOLID (no hole punched).
                            // The keep's gate torches back onto z-1 (wall row); the
                            // cabin torch backs onto the door wall plane in x.
                            let back_z = tz - 1;
                            println!("-- X/Y slice at z={back_z} (wall behind torch must be solid #) --");
                            for wy in (ty - 3..=ty + 3).rev() {
                                let mut line = String::new();
                                for wx in (tx - 4)..=(tx + 4) {
                                    let b = *cells.get(&(wx, wy, back_z)).unwrap_or(&AIR);
                                    line.push(glyph(b));
                                }
                                println!("  y={wy:>4} {line}");
                            }
                        }
                        break 'find;
                    }
                }
            }
        }

        // Tree-clearance top-down map: find a structure, mark its footprint box and
        // every emitted-tree root in the area. After the #143 fix no 't' should fall
        // inside the cleared box (shown as the bracketed region).
        'tree: for &seed in &[11u64, 1, 42, 7, 1234, 5, 9, 100] {
            let r = 30;
            for scz in -r..=r {
                for scx in -r..=r {
                    let sd = struct_for_cell(scx, scz, seed);
                    if !sd.present || sd.typ == STRUCT_NONE {
                        continue;
                    }
                    let clear = struct_footprint_reach(sd.typ) + STRUCT_TREE_CLEARANCE;
                    let span = clear + 8;
                    // Only dump a structure that actually has trees in the surrounding
                    // ring, so the cleared box contrasts with a forested margin.
                    let mut ring_trees = 0;
                    for dz in -span..=span {
                        for dx in -span..=span {
                            let wx = sd.anchor_wx + dx;
                            let wz = sd.anchor_wz + dz;
                            let (ccx, ccz) = tree_cell(wx, wz);
                            let td = tree_for_cell(ccx, ccz, seed);
                            if td.present
                                && td.root_wx == wx
                                && td.root_wz == wz
                                && !tree_blocked_by_structure(wx, wz, seed)
                            {
                                ring_trees += 1;
                            }
                        }
                    }
                    if ring_trees < 4 {
                        continue;
                    }
                    println!(
                        "\n=== tree clearance map: structure type {} seed {seed} anchor ({},{}) clear={clear} ===",
                        sd.typ, sd.anchor_wx, sd.anchor_wz
                    );
                    println!("  S=anchor  t=tree root  [ ]=cleared box  .=open");
                    for dz in (-span..=span).rev() {
                        let mut line = String::new();
                        for dx in -span..=span {
                            let wx = sd.anchor_wx + dx;
                            let wz = sd.anchor_wz + dz;
                            let in_box = dx.abs() <= clear && dz.abs() <= clear;
                            let ch = if dx == 0 && dz == 0 {
                                'S'
                            } else {
                                // Is a tree emitted with its root here?
                                let (ccx, ccz) = tree_cell(wx, wz);
                                let td = tree_for_cell(ccx, ccz, seed);
                                let has_tree = td.present
                                    && td.root_wx == wx
                                    && td.root_wz == wz
                                    && !tree_blocked_by_structure(wx, wz, seed);
                                if has_tree {
                                    't'
                                } else if in_box {
                                    ' '
                                } else {
                                    '.'
                                }
                            };
                            line.push(ch);
                        }
                        println!("  {line}");
                    }
                    break 'tree;
                }
            }
        }
    }

#[test]
#[ignore] // manual bench: measures the shared_column_data memo win (run with --ignored --nocapture)
fn bench_gen_cache_share() {
    use std::time::Instant;
    let seed = 2026u64;
    let mut g = TerrainGen::new();
    g.seed(seed);
    let mut ch = crate::chunk::PaletteChunk::new(ChunkCoord { x: 0, y: 0, z: 0 }, 0);
    g.generate(ChunkCoord { x: 0, y: 0, z: 0 }, &mut ch); // warm

    let t0 = Instant::now();
    let mut n = 0u32;
    for cx in -5..=5 {
        for cz in -5..=5 {
            for cy in -1..=3 {
                let cc = ChunkCoord { x: cx, y: cy, z: cz };
                let mut ch = crate::chunk::PaletteChunk::new(cc, 0);
                g.generate(cc, &mut ch);
                n += 1;
            }
        }
    }
    let full = t0.elapsed();

    // cache-build cost alone, once per (x,z) column (what a shared cache would pay)
    let t1 = Instant::now();
    let mut k = 0u32;
    for cx in -5..=5 {
        for cz in -5..=5 {
            let wx = cx * K_CHUNK_DIM;
            let wz = cz * K_CHUNK_DIM;
            let ac = build_anchor_cache(wx, wz, seed);
            let cc2 = build_column_cache(wx, wz, seed, &ac);
            std::hint::black_box((&ac, &cc2));
            k += 1;
        }
    }
    let caches = t1.elapsed();
    println!(
        "FULL: {} chunks in {:?} ({:.3} ms/chunk) | CACHES once-per-column: {} cols in {:?} ({:.3} ms/col)",
        n, full, full.as_secs_f64() * 1000.0 / n as f64,
        k, caches, caches.as_secs_f64() * 1000.0 / k as f64
    );
}


    // =======================================================================
    // #179 looping world: the world is a torus with period WORLD_PERIOD in x/z.
    // =======================================================================

    // MASTER wrap property: a chunk and its torus twin (shifted by
    // WORLD_PERIOD_CHUNKS on x and/or z) are byte-identical, including chunks
    // straddling the seam and chunks on the far side of the map.
    #[test]
    fn world_wraps_periodically() {
        const W: i32 = WORLD_PERIOD_CHUNKS;
        for seed in [11u64, 42, 1234] {
            let mut g = TerrainGen::new();
            g.seed(seed);
            let coords = [
                ChunkCoord { x: 0, y: 0, z: 0 },
                ChunkCoord { x: 0, y: -1, z: 0 },
                ChunkCoord { x: 0, y: 1, z: 5 },
                ChunkCoord { x: W - 1, y: 0, z: 0 },      // seam edge (x)
                ChunkCoord { x: 3, y: 0, z: W - 1 },      // seam edge (z)
                ChunkCoord { x: W - 1, y: 0, z: W - 1 },  // corner
                ChunkCoord { x: W / 2, y: 0, z: 7 },      // far side
                ChunkCoord { x: -1, y: 0, z: 2 },         // negative frame
                ChunkCoord { x: 100, y: 2, z: -1 },
            ];
            for c in coords {
                let h0 = g.content_hash(c);
                let hx = g.content_hash(ChunkCoord { x: c.x + W, y: c.y, z: c.z });
                let hz = g.content_hash(ChunkCoord { x: c.x, y: c.y, z: c.z + W });
                let hxz = g.content_hash(ChunkCoord { x: c.x + W, y: c.y, z: c.z + W });
                let hneg = g.content_hash(ChunkCoord { x: c.x - W, y: c.y, z: c.z - W });
                assert_eq!(h0, hx, "seed {seed} chunk {c:?}: +W on x differs");
                assert_eq!(h0, hz, "seed {seed} chunk {c:?}: +W on z differs");
                assert_eq!(h0, hxz, "seed {seed} chunk {c:?}: +W on x+z differs");
                assert_eq!(h0, hneg, "seed {seed} chunk {c:?}: -W on x+z differs");
            }
        }
    }

    // Column-level periodicity of the pure query helpers: heights, biomes,
    // ocean/river fields and structure cells agree between a column and its
    // torus twin, including out-of-range frames (what a seam-adjacent chunk
    // actually asks for while decorating).
    #[test]
    fn wrap_column_queries_periodic() {
        const W: i32 = WORLD_PERIOD;
        for seed in [11u64, 7] {
            for &(wx, wz) in &[(0, 0), (5, W - 3), (W - 1, 17), (W / 2, W / 2), (123, 456)] {
                for &(dx, dz) in &[(W, 0), (0, W), (-W, -W), (W, W)] {
                    let (qx, qz) = (wx + dx, wz + dz);
                    assert_eq!(
                        surface_height(wx, wz, seed),
                        surface_height(qx, qz, seed),
                        "height differs at ({wx},{wz}) vs ({qx},{qz}) seed {seed}"
                    );
                    assert_eq!(
                        voronoi_biome(wx, wz, seed),
                        voronoi_biome(qx, qz, seed),
                        "biome differs at ({wx},{wz}) vs ({qx},{qz}) seed {seed}"
                    );
                    assert_eq!(
                        is_ocean_column(wx as f32, wz as f32, seed),
                        is_ocean_column(qx as f32, qz as f32, seed),
                        "ocean flag differs at ({wx},{wz}) seed {seed}"
                    );
                    assert_eq!(
                        cave_entrance_depth(wx, wz, seed),
                        cave_entrance_depth(qx, qz, seed),
                        "entrance depth differs at ({wx},{wz}) seed {seed}"
                    );
                }
            }
        }
    }

    // The height field is CONTINUOUS across the seam: the step between the last
    // column (x = W-1) and the first (x = 0) is no larger than the roughest step
    // found in the interior. A lattice that failed to close would show up here
    // as a cliff along x = 0.
    #[test]
    fn wrap_seam_has_no_cliff() {
        const W: i32 = WORLD_PERIOD;
        for seed in [11u64, 42] {
            let mut max_seam = 0i32;
            let mut max_interior = 0i32;
            for wz in (0..2048).step_by(13) {
                let a = surface_height(W - 1, wz, seed);
                let b = surface_height(0, wz, seed);
                max_seam = max_seam.max((a - b).abs());
                // Interior reference steps at a few x positions.
                for wx in [1000, 5000, 11000] {
                    let c = surface_height(wx, wz, seed);
                    let d = surface_height(wx + 1, wz, seed);
                    max_interior = max_interior.max((c - d).abs());
                }
            }
            assert!(
                max_seam <= max_interior + 2,
                "seed {seed}: seam step {max_seam} exceeds interior max step {max_interior} + 2 (cliff at the seam)"
            );
        }
    }

    // Structures and trees are continuous across the seam: the two chunk columns
    // flanking x = 0 generate identical bytes whether addressed canonically or
    // from the other side's frame (x = -1 vs x = W_CHUNKS-1), so a build or a
    // canopy straddling the seam is stamped consistently into both neighbours.
    #[test]
    fn wrap_seam_neighbours_consistent() {
        let mut g = TerrainGen::new();
        g.seed(11);
        for cz in [0, 100, 1500] {
            for cy in -1..=2 {
                let east = ChunkCoord { x: 0, y: cy, z: cz };
                let west_canonical = ChunkCoord { x: WORLD_PERIOD_CHUNKS - 1, y: cy, z: cz };
                let west_frame = ChunkCoord { x: -1, y: cy, z: cz };
                assert_eq!(g.content_hash(west_canonical), g.content_hash(west_frame));
                // Determinism of the pair (regen twice, byte-stable).
                assert_eq!(g.content_hash(east), g.content_hash(east));
            }
        }
    }

}
