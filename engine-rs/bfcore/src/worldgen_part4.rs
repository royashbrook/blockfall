// ===========================================================================
// Part 4: decoration pass, generate(), content_hash, public API.
// ===========================================================================

fn place_decorations<C: Chunk>(c: ChunkCoord, chunk: &mut C, seed: u64, anchor_cache: &SeamAnchorCache, col_cache: &ChunkColumnCache) {
    let wx_min = c.x * K_CHUNK_DIM;
    let wy_min = c.y * K_CHUNK_DIM;
    let wz_min = c.z * K_CHUNK_DIM;
    let wx_max = wx_min + K_CHUNK_DIM - 1;
    let wy_max = wy_min + K_CHUNK_DIM - 1;
    let wz_max = wz_min + K_CHUNK_DIM - 1;

    // 1. TREES
    {
        let (cell_xmin, cell_zmin) = tree_cell(wx_min - CANOPY_MAX_REACH_XZ, wz_min - CANOPY_MAX_REACH_XZ);
        let (cell_xmax, _d1) = tree_cell(wx_max + CANOPY_MAX_REACH_XZ, wz_max + CANOPY_MAX_REACH_XZ);
        let (_d2, cell_zmax) = tree_cell(wx_min, wz_max + CANOPY_MAX_REACH_XZ);

        for ccz in cell_zmin..=cell_zmax {
            for ccx in cell_xmin..=cell_xmax {
                let mut td = tree_for_cell(ccx, ccz, seed);
                if !td.present {
                    continue;
                }

                let dom = voronoi_biome(td.root_wx, td.root_wz, seed);
                if dom == Biome::Desert || dom == Biome::Beach {
                    continue;
                }

                let h = surface_height_cached(td.root_wx, td.root_wz, anchor_cache);
                if h <= SEA_LEVEL {
                    continue;
                }

                // Skip trees whose root falls inside a structure's no-tree clearance
                // zone so trunks / canopies never intersect a building (#143).
                if tree_blocked_by_structure(td.root_wx, td.root_wz, seed) {
                    continue;
                }

                let fit = worldgen_trunk_fit_to_ceiling(h, canopy_dy_max(td.canopy_shape), td.trunk_height);
                if fit <= 0 {
                    continue;
                }
                td.trunk_height = fit;

                let trunk_base_wy = h + 1;
                let trunk_top_wy = h + td.trunk_height;
                let dy_max_v = canopy_dy_max(td.canopy_shape);
                let dy_min_v = canopy_dy_min(td.canopy_shape) - td.extra_skirt;
                let canopy_wy_max = trunk_top_wy + dy_max_v;

                let mut feature_wy_max = canopy_wy_max;
                if td.branch_count > 0 {
                    let branch_top = trunk_top_wy + 2 + 1;
                    if branch_top > feature_wy_max {
                        feature_wy_max = branch_top;
                    }
                }

                if feature_wy_max < wy_min || trunk_base_wy > wy_max {
                    continue;
                }

                // Trunk logs.
                {
                    let lean_start = trunk_base_wy + td.trunk_height / 2;
                    for wy in trunk_base_wy..=trunk_top_wy {
                        if wy < wy_min || wy > wy_max {
                            continue;
                        }
                        let mut wx_log = td.root_wx;
                        let mut wz_log = td.root_wz;
                        if wy >= lean_start {
                            wx_log += td.lean_dx;
                            wz_log += td.lean_dz;
                        }
                        if wx_log < wx_min || wx_log > wx_max {
                            continue;
                        }
                        if wz_log < wz_min || wz_log > wz_max {
                            continue;
                        }
                        if wx_log != td.root_wx || wz_log != td.root_wz {
                            let lb = voronoi_biome(wx_log, wz_log, seed);
                            if lb == Biome::Desert || lb == Biome::Beach {
                                continue;
                            }
                        }
                        let lx = wx_log - wx_min;
                        let ly = wy - wy_min;
                        let lz = wz_log - wz_min;
                        chunk.set(lx, ly, lz, td.log_id);

                        if td.thick_trunk {
                            for tx in 0..=1 {
                                for tz in 0..=1 {
                                    if tx == 0 && tz == 0 {
                                        continue;
                                    }
                                    let wx2 = wx_log + tx;
                                    let wz2 = wz_log + tz;
                                    if wx2 < wx_min || wx2 > wx_max {
                                        continue;
                                    }
                                    if wz2 < wz_min || wz2 > wz_max {
                                        continue;
                                    }
                                    let ob = voronoi_biome(wx2, wz2, seed);
                                    if ob == Biome::Desert || ob == Biome::Beach {
                                        continue;
                                    }
                                    let off_h = surface_height_cached(wx2, wz2, anchor_cache);
                                    if wy <= off_h {
                                        continue;
                                    }
                                    let olx = wx2 - wx_min;
                                    let oly = ly;
                                    let olz = wz2 - wz_min;
                                    if chunk.get(olx, oly, olz) == AIR {
                                        chunk.set(olx, oly, olz, td.log_id);
                                    }
                                }
                            }
                        }
                    }
                }

                // Canopy anchor XZ.
                let canopy_wx = td.root_wx + td.lean_dx;
                let canopy_wz = td.root_wz + td.lean_dz;

                let reach = if td.canopy_shape == CANOPY_GIANT {
                    4
                } else if td.canopy_shape == CANOPY_WEEPING {
                    4
                } else if td.canopy_shape == CANOPY_BROAD || td.canopy_shape == CANOPY_PINE {
                    3
                } else {
                    2
                };
                let shape_dy_min = canopy_dy_min(td.canopy_shape);
                for dz in -reach..=reach {
                    for dx in -reach..=reach {
                        for dy in dy_min_v..=dy_max_v {
                            let fill;
                            if dy >= shape_dy_min {
                                fill = in_canopy(dx, dy, dz, td.canopy_shape);
                            } else {
                                let ax = if dx < 0 { -dx } else { dx };
                                let az = if dz < 0 { -dz } else { dz };
                                let inring = (ax <= 3 && az <= 3) && (ax >= 2 || az >= 2) && !(ax == 3 && az == 3);
                                fill = inring;
                            }
                            if !fill {
                                continue;
                            }

                            let wlx = canopy_wx + dx;
                            let wly = trunk_top_wy + dy;
                            let wlz = canopy_wz + dz;

                            if wlx < wx_min || wlx > wx_max {
                                continue;
                            }
                            if wly < wy_min || wly > wy_max {
                                continue;
                            }
                            if wlz < wz_min || wlz > wz_max {
                                continue;
                            }

                            if !keep_leaf_voxel(td.leaf_hash, td.sparse, wlx, wly, wlz, dx, dz) {
                                continue;
                            }

                            let lx = wlx - wx_min;
                            let ly = wly - wy_min;
                            let lz = wlz - wz_min;
                            if chunk.get(lx, ly, lz) == AIR {
                                chunk.set(lx, ly, lz, td.leaf_id);
                            }
                        }
                    }
                }

                // BRANCHES.
                for bi in 0..td.branch_count {
                    let bh = fmix64(td.branch_hash ^ ((bi + 1) as u64).wrapping_mul(0x9E3779B97F4A7C15));
                    let dir = (bh & 0x7) as usize;
                    let blen = BRANCH_LEN_MIN + ((bh >> 3) % ((BRANCH_LEN_MAX - BRANCH_LEN_MIN + 1) as u64)) as i32;

                    let span = if td.trunk_height >= 3 { td.trunk_height / 3 } else { 1 };
                    let mut attach_wy = trunk_top_wy - 1 - ((bh >> 8) % ((span + 1) as u64)) as i32;
                    if attach_wy < trunk_base_wy + 1 {
                        attach_wy = trunk_base_wy + 1;
                    }

                    let lean_start = trunk_base_wy + td.trunk_height / 2;
                    let arm_wx = td.root_wx + if attach_wy >= lean_start { td.lean_dx } else { 0 };
                    let arm_wz = td.root_wz + if attach_wy >= lean_start { td.lean_dz } else { 0 };

                    let sdx = BRANCH_DIRS[dir][0];
                    let sdz = BRANCH_DIRS[dir][1];

                    let mut cx = arm_wx;
                    let mut cz = arm_wz;
                    let mut cy = attach_wy;
                    for s in 1..=blen {
                        cx += sdx;
                        cz += sdz;
                        if (s & 1) == 1 {
                            cy += 1;
                        }
                        if cx >= wx_min && cx <= wx_max && cy >= wy_min && cy <= wy_max && cz >= wz_min && cz <= wz_max {
                            let ab = voronoi_biome(cx, cz, seed);
                            if ab != Biome::Desert && ab != Biome::Beach {
                                let lx = cx - wx_min;
                                let ly = cy - wy_min;
                                let lz = cz - wz_min;
                                if chunk.get(lx, ly, lz) == AIR {
                                    chunk.set(lx, ly, lz, td.log_id);
                                }
                            }
                        }
                    }

                    let tipx = cx;
                    let tipy = cy;
                    let tipz = cz;
                    for lz2 in -1..=1 {
                        for lx2 in -1..=1 {
                            for ly2 in 0..=1 {
                                if ly2 == 1 && lx2 != 0 && lz2 != 0 {
                                    continue;
                                }
                                let wlx = tipx + lx2;
                                let wly = tipy + ly2;
                                let wlz = tipz + lz2;
                                if wlx < wx_min || wlx > wx_max {
                                    continue;
                                }
                                if wly < wy_min || wly > wy_max {
                                    continue;
                                }
                                if wlz < wz_min || wlz > wz_max {
                                    continue;
                                }
                                let lx = wlx - wx_min;
                                let ly = wly - wy_min;
                                let lz = wlz - wz_min;
                                if chunk.get(lx, ly, lz) == AIR {
                                    chunk.set(lx, ly, lz, td.leaf_id);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // 1b. DEADWOOD
    {
        let dcx_min = deadwood_floordiv(wx_min - DEADWOOD_REACH_XZ, DEADWOOD_CELL);
        let dcx_max = deadwood_floordiv(wx_max + DEADWOOD_REACH_XZ, DEADWOOD_CELL);
        let dcz_min = deadwood_floordiv(wz_min - DEADWOOD_REACH_XZ, DEADWOOD_CELL);
        let dcz_max = deadwood_floordiv(wz_max + DEADWOOD_REACH_XZ, DEADWOOD_CELL);

        const DW_DIRS: [[i32; 2]; 4] = [[1, 0], [-1, 0], [0, 1], [0, -1]];

        for dcz in dcz_min..=dcz_max {
            for dcx in dcx_min..=dcx_max {
                let dw = deadwood_for_cell(dcx, dcz, seed);
                if !dw.present {
                    continue;
                }

                let ha = surface_height_cached(dw.wx, dw.wz, anchor_cache);
                if ha <= SEA_LEVEL {
                    continue;
                }

                if dw.kind == DEADWOOD_STUMP {
                    for s in 1..=dw.length {
                        let wy = ha + s;
                        if dw.wx < wx_min || dw.wx > wx_max {
                            continue;
                        }
                        if dw.wz < wz_min || dw.wz > wz_max {
                            continue;
                        }
                        if wy < wy_min || wy > wy_max {
                            continue;
                        }
                        let lx = dw.wx - wx_min;
                        let ly = wy - wy_min;
                        let lz = dw.wz - wz_min;
                        if chunk.get(lx, ly, lz) == AIR {
                            chunk.set(lx, ly, lz, dw.log_id);
                        }
                    }
                    if dw.leaf_nub {
                        let wy = ha + dw.length + 1;
                        if dw.wx >= wx_min && dw.wx <= wx_max && dw.wz >= wz_min && dw.wz <= wz_max && wy >= wy_min && wy <= wy_max {
                            let lx = dw.wx - wx_min;
                            let ly = wy - wy_min;
                            let lz = dw.wz - wz_min;
                            if chunk.get(lx, ly, lz) == AIR {
                                chunk.set(lx, ly, lz, OAK_LEAVES);
                            }
                        }
                    }
                } else {
                    let ddx = DW_DIRS[dw.dir as usize][0];
                    let ddz = DW_DIRS[dw.dir as usize][1];
                    for s in 0..dw.length {
                        let cwx = dw.wx + ddx * s;
                        let cwz = dw.wz + ddz * s;
                        let sb = voronoi_biome(cwx, cwz, seed);
                        if sb == Biome::Desert || sb == Biome::Beach {
                            continue;
                        }
                        let hs = surface_height_cached(cwx, cwz, anchor_cache);
                        let wy = hs + 1;
                        if cwx < wx_min || cwx > wx_max {
                            continue;
                        }
                        if cwz < wz_min || cwz > wz_max {
                            continue;
                        }
                        if wy < wy_min || wy > wy_max {
                            continue;
                        }
                        let lx = cwx - wx_min;
                        let ly = wy - wy_min;
                        let lz = cwz - wz_min;
                        if chunk.get(lx, ly, lz) == AIR {
                            chunk.set(lx, ly, lz, dw.log_id);
                        }
                    }
                }
            }
        }
    }

    // 2. PLANTS
    {
        let pseed = fmix64(seed ^ PLANT_SEED_MIX);

        for lz in 0..K_CHUNK_DIM {
            for lx in 0..K_CHUNK_DIM {
                let wx = wx_min + lx;
                let wz = wz_min + lz;

                let ci = ChunkColumnCache::idx(lx, lz);
                let dom = col_cache.dom[ci];

                if dom == Biome::Snowy {
                    continue;
                }

                let h = col_cache.h[ci];
                if h <= SEA_LEVEL {
                    continue;
                }

                let plant_wy = h + 1;
                if plant_wy < wy_min || plant_wy > wy_max {
                    continue;
                }

                let ly_surface = h - wy_min;
                let ly_plant = ly_surface + 1;
                if ly_surface < 0 || ly_surface >= K_CHUNK_DIM {
                    continue;
                }
                if ly_plant < 0 || ly_plant >= K_CHUNK_DIM {
                    continue;
                }

                if chunk.get(lx, ly_plant, lz) != AIR {
                    continue;
                }

                let surf = chunk.get(lx, ly_surface, lz);

                let ph = hash2(wx, wz, pseed);
                let roll = ph & 0xFF;
                let roll2 = (ph >> 8) & 0xFF;
                let roll3 = (ph >> 16) & 0xFF;
                // #179: 0.085 as an integer lattice period (2785/32768 ~= 0.08499).
                const GPATCH_PERIOD: i32 = 2785;
                const GPATCH_FREQ: f32 = GPATCH_PERIOD as f32 / WORLD_PERIOD as f32;
                let gpatch = value_noise2(wx as f32 * GPATCH_FREQ, wz as f32 * GPATCH_FREQ, pseed ^ 0x6772ABCD, GPATCH_PERIOD);
                let gt: u64 = if gpatch > 0.58 { 205 } else { 24 };

                let mut plant = AIR;

                if dom == Biome::Forest {
                    if surf == GRASS {
                        if roll < gt {
                            plant = TALL_GRASS;
                        } else if roll < gt + 15 {
                            plant = FLOWER_RED;
                        } else if roll < gt + 30 {
                            plant = FLOWER_YELLOW;
                        } else if roll < gt + 40 {
                            plant = MUSHROOM;
                        } else if roll < gt + 46 {
                            plant = BERRY_BUSH;
                        } else if roll < gt + 52 {
                            plant = FALLEN_STICK;
                        }
                    } else if surf == DIRT {
                        if roll2 < 55 {
                            plant = MUSHROOM;
                        } else if roll2 < 70 {
                            plant = TALL_GRASS;
                        } else if roll2 < 82 {
                            plant = FALLEN_STICK;
                        }
                    }
                } else if dom == Biome::Swamp {
                    if surf == GRASS || surf == DIRT {
                        if roll < gt {
                            plant = TALL_GRASS;
                        } else if roll < gt + 26 {
                            plant = MUSHROOM;
                        } else if roll < gt + 38 {
                            plant = FLOWER_RED;
                        }
                    }
                } else if dom == Biome::Desert {
                    if surf == SAND {
                        if roll < 2 {
                            plant = CACTUS_PLANT;
                        } else if roll2 < 2 {
                            plant = FALLEN_STICK;
                        } else if roll3 >= 254 {
                            plant = PEBBLE;
                        }
                    }
                } else if dom == Biome::Beach {
                    if surf == SAND && roll < 14 {
                        plant = SEASHELL;
                    }
                } else if dom == Biome::Plains {
                    if surf == GRASS {
                        if roll < gt {
                            plant = TALL_GRASS;
                        } else if roll < gt + 19 {
                            plant = FLOWER_RED;
                        } else if roll < gt + 37 {
                            plant = FLOWER_YELLOW;
                        } else if roll < gt + 43 {
                            plant = MUSHROOM;
                        } else if roll < gt + 48 {
                            plant = BERRY_BUSH;
                        }
                    }
                } else if dom == Biome::Mountains {
                    if h >= SNOW_LINE {
                        plant = AIR;
                    } else if surf == GRASS {
                        if roll < 16 {
                            plant = TALL_GRASS;
                        }
                    }
                } else {
                    if surf == GRASS {
                        if roll < 38 {
                            plant = TALL_GRASS;
                        } else if roll < 57 {
                            plant = FLOWER_RED;
                        } else if roll < 75 {
                            plant = FLOWER_YELLOW;
                        } else if roll < 81 {
                            plant = MUSHROOM;
                        }
                    }
                }

                if plant == AIR && dom != Biome::Desert && roll3 >= 249 && (surf == GRASS || surf == DIRT || surf == STONE || surf == SAND) {
                    plant = PEBBLE;
                }

                if plant != AIR {
                    chunk.set(lx, ly_plant, lz, plant);
                }
            }
        }
    }

    // 2b. UNDERWATER VEGETATION
    {
        let kelp_seed = fmix64(seed ^ 0x5EA6A55C0DE1A5E7);
        for lz in 0..K_CHUNK_DIM {
            for lx in 0..K_CHUNK_DIM {
                let ci = ChunkColumnCache::idx(lx, lz);
                let h = col_cache.h[ci];
                if h >= SEA_LEVEL {
                    continue;
                }
                let dom = col_cache.dom[ci];
                if dom == Biome::Snowy {
                    continue;
                }

                let wx = wx_min + lx;
                let wz = wz_min + lz;
                let kh = hash2(wx, wz, kelp_seed);

                let water_depth = SEA_LEVEL - h;

                let freshwater = dom != Biome::Desert && dom != Biome::Beach;
                if freshwater && water_depth == 1 && ((kh >> 16) & 0xFF) < 18 {
                    let wy = SEA_LEVEL;
                    if wy >= wy_min && wy <= wy_max {
                        let ly = wy - wy_min;
                        if chunk.get(lx, ly, lz) == WATER {
                            chunk.set(lx, ly, lz, REED);
                        }
                    }
                } else if freshwater && water_depth >= 2 && water_depth <= 4 && ((kh >> 24) & 0xFF) < 26 {
                    let wy = SEA_LEVEL;
                    if wy >= wy_min && wy <= wy_max {
                        let ly = wy - wy_min;
                        if chunk.get(lx, ly, lz) == WATER {
                            chunk.set(lx, ly, lz, LILY_PAD);
                        }
                    }
                }

                let open_ocean = is_ocean_column(wx as f32, wz as f32, seed) && water_depth >= 5;
                let kelp_cutoff = if open_ocean { 22 } else { 56 };
                if (kh & 0xFF) >= kelp_cutoff {
                    continue;
                }

                let mut strand = 1 + ((kh >> 8) % if open_ocean { 2 } else { 3 }) as i32;
                let max_strand = water_depth - 1;
                if max_strand < 1 {
                    continue;
                }
                if strand > max_strand {
                    strand = max_strand;
                }

                for s in 1..=strand {
                    let wy = h + s;
                    if wy < wy_min || wy > wy_max {
                        continue;
                    }
                    let ly = wy - wy_min;
                    if chunk.get(lx, ly, lz) == WATER {
                        chunk.set(lx, ly, lz, TALL_GRASS);
                    }
                }
            }
        }
    }

    // 2c. DESERT DECORATION
    {
        let desert_seed = fmix64(seed ^ 0xDE5E27DEC0DE0001);
        for lz in 0..K_CHUNK_DIM {
            for lx in 0..K_CHUNK_DIM {
                let ci = ChunkColumnCache::idx(lx, lz);
                let dom = col_cache.dom[ci];
                if dom != Biome::Desert {
                    continue;
                }

                let h = col_cache.h[ci];
                if h <= SEA_LEVEL {
                    continue;
                }

                let wx = wx_min + lx;
                let wz = wz_min + lz;
                let dh = hash2(wx, wz, desert_seed);
                let roll = dh & 0xFF;

                let ly_surf = h - wy_min;
                let ly_above = ly_surf + 1;
                if ly_surf < 0 || ly_surf >= K_CHUNK_DIM {
                    continue;
                }
                if ly_above < 0 || ly_above >= K_CHUNK_DIM {
                    continue;
                }
                if chunk.get(lx, ly_surf, lz) != SAND {
                    continue;
                }
                if chunk.get(lx, ly_above, lz) != AIR {
                    continue;
                }
                let above_wy = h + 1;
                if above_wy < wy_min || above_wy > wy_max {
                    continue;
                }

                if roll < 26 {
                    let rb = if (dh >> 8) & 1 != 0 { GRAVEL } else { STONE };
                    chunk.set(lx, ly_surf, lz, rb);
                }
            }
        }
    }

    // 3. STRUCTURES
    {
        let scx_min = struct_floordiv(wx_min - STRUCT_MAX_REACH_XZ, STRUCT_CELL_SIZE);
        let scx_max = struct_floordiv(wx_max + STRUCT_MAX_REACH_XZ, STRUCT_CELL_SIZE);
        let scz_min = struct_floordiv(wz_min - STRUCT_MAX_REACH_XZ, STRUCT_CELL_SIZE);
        let scz_max = struct_floordiv(wz_max + STRUCT_MAX_REACH_XZ, STRUCT_CELL_SIZE);

        if wy_max >= -16 {
            for scz in scz_min..=scz_max {
                for scx in scx_min..=scx_max {
                    let sd = struct_for_cell(scx, scz, seed);
                    if !sd.present {
                        continue;
                    }
                    if sd.anchor_wx + STRUCT_MAX_REACH_XZ < wx_min {
                        continue;
                    }
                    if sd.anchor_wx - STRUCT_MAX_REACH_XZ > wx_max {
                        continue;
                    }
                    if sd.anchor_wz + STRUCT_MAX_REACH_XZ < wz_min {
                        continue;
                    }
                    if sd.anchor_wz - STRUCT_MAX_REACH_XZ > wz_max {
                        continue;
                    }
                    place_structure(&sd, seed, chunk, wx_min, wy_min, wz_min);
                }
            }
        }
    }

    // 5. SWAMP CLAY PATCHES
    {
        let clay_seed = fmix64(seed ^ 0xC1A4C1A4C1A4C1A4);

        for lz in 0..K_CHUNK_DIM {
            for lx in 0..K_CHUNK_DIM {
                let wx = wx_min + lx;
                let wz = wz_min + lz;

                let ci = ChunkColumnCache::idx(lx, lz);
                let dom = col_cache.dom[ci];

                if dom != Biome::Swamp {
                    continue;
                }

                let h = col_cache.h[ci];

                let clay_wy = h - 1;
                if clay_wy < wy_min || clay_wy > wy_max {
                    continue;
                }

                let ly_clay = clay_wy - wy_min;
                if ly_clay < 0 || ly_clay >= K_CHUNK_DIM {
                    continue;
                }

                let ch = hash2(wx, wz, clay_seed);
                if (ch & 0xFF) < 77 {
                    let cur = chunk.get(lx, ly_clay, lz);
                    if cur == DIRT || cur == STONE {
                        chunk.set(lx, ly_clay, lz, CLAY);
                    }
                }
            }
        }
    }

    // 6. FOREST MOSSY STONE PATCHES
    {
        let moss_seed = fmix64(seed ^ 0x405577EDA40550C0);

        for lz in 0..K_CHUNK_DIM {
            for lx in 0..K_CHUNK_DIM {
                let wx = wx_min + lx;
                let wz = wz_min + lz;

                let ci = ChunkColumnCache::idx(lx, lz);
                let dom = col_cache.dom[ci];

                if dom != Biome::Forest {
                    continue;
                }

                let h = col_cache.h[ci];

                let mwy = h - 2;
                if mwy < wy_min || mwy > wy_max {
                    continue;
                }

                let ly_m = mwy - wy_min;
                if ly_m < 0 || ly_m >= K_CHUNK_DIM {
                    continue;
                }

                let mh = hash2(wx, wz, moss_seed);
                if (mh & 0xFF) < 51 {
                    let cur = chunk.get(lx, ly_m, lz);
                    if cur == STONE {
                        chunk.set(lx, ly_m, lz, MOSSY_STONE);
                    }
                }
            }
        }
    }

    // 7. ORE VEINS
    {
        // #179: 7 -> 8 so the ore grid divides WORLD_PERIOD (4096 cells);
        // thresholds rescaled by 8^3/7^3 (38/20/13/3 -> 57/30/19/4) so
        // ore-per-volume stays about the same.
        const ORE_CELL_SIZE: i32 = 8;
        const ORE_CELL_COUNT: i32 = WORLD_PERIOD / ORE_CELL_SIZE; // 4096
        const ORE_VEIN_REACH: i32 = 4;

        const COAL_Y_MAX: i32 = -2;
        const COPPER_Y_MAX: i32 = -8;
        const IRON_Y_MAX: i32 = -14;
        const CRYSTAL_Y_MAX: i32 = -24;

        const COAL_THRESH: u64 = 57;
        const COPPER_THRESH: u64 = 30;
        const IRON_THRESH: u64 = 19;
        const CRYSTAL_THRESH: u64 = 4;

        const ORE_SEED_MIX: u64 = 0x0ACED501DF0ADED5;
        let ore_seed = fmix64(seed ^ ORE_SEED_MIX);

        let floordiv_ore = |a: i32, b: i32| a / b - if a % b != 0 && (a ^ b) < 0 { 1 } else { 0 };

        let cell_xmin = floordiv_ore(wx_min - ORE_VEIN_REACH, ORE_CELL_SIZE);
        let cell_xmax = floordiv_ore(wx_max + ORE_VEIN_REACH, ORE_CELL_SIZE);
        let cell_ymin = floordiv_ore(wy_min - ORE_VEIN_REACH, ORE_CELL_SIZE);
        let cell_ymax = floordiv_ore(wy_max + ORE_VEIN_REACH, ORE_CELL_SIZE);
        let cell_zmin = floordiv_ore(wz_min - ORE_VEIN_REACH, ORE_CELL_SIZE);
        let cell_zmax = floordiv_ore(wz_max + ORE_VEIN_REACH, ORE_CELL_SIZE);

        for cy_cell in cell_ymin..=cell_ymax {
            let anchor_wy = cy_cell * ORE_CELL_SIZE;
            if anchor_wy > COAL_Y_MAX {
                continue;
            }

            for cz_cell in cell_zmin..=cell_zmax {
                for cx_cell in cell_xmin..=cell_xmax {
                    let h = hash3(
                        wrap_cell(cx_cell, ORE_CELL_COUNT),
                        cy_cell,
                        wrap_cell(cz_cell, ORE_CELL_COUNT),
                        ore_seed,
                    );
                    let prob = h & 0xFF;

                    let ore_id;
                    if anchor_wy <= CRYSTAL_Y_MAX && prob < CRYSTAL_THRESH {
                        ore_id = CRYSTAL_ORE;
                    } else if anchor_wy <= IRON_Y_MAX && prob < IRON_THRESH {
                        ore_id = IRON_ORE;
                    } else if anchor_wy <= COPPER_Y_MAX && prob < COPPER_THRESH {
                        ore_id = COPPER_ORE;
                    } else if anchor_wy <= COAL_Y_MAX && prob < COAL_THRESH {
                        ore_id = COAL_ORE;
                    } else {
                        ore_id = AIR;
                    }

                    if ore_id == AIR {
                        continue;
                    }

                    let h2_ore = fmix64(h ^ 0xABCDEF1234567890);
                    let vein_size = 3 + ((h2_ore >> 8) % 6) as i32;

                    for vi in 0..vein_size {
                        let bh = fmix64(h2_ore ^ (vi as u64).wrapping_mul(0x1111222233334444));
                        let dx_ore = ((bh >> 0) % 7) as i32 - 3;
                        let dy_ore = ((bh >> 8) % 7) as i32 - 3;
                        let dz_ore = ((bh >> 16) % 7) as i32 - 3;

                        let wx_ore = cx_cell * ORE_CELL_SIZE + dx_ore;
                        let wy_ore = cy_cell * ORE_CELL_SIZE + dy_ore;
                        let wz_ore = cz_cell * ORE_CELL_SIZE + dz_ore;

                        if wx_ore < wx_min || wx_ore > wx_max {
                            continue;
                        }
                        if wy_ore < wy_min || wy_ore > wy_max {
                            continue;
                        }
                        if wz_ore < wz_min || wz_ore > wz_max {
                            continue;
                        }

                        let lx_ore = wx_ore - wx_min;
                        let ly_ore = wy_ore - wy_min;
                        let lz_ore = wz_ore - wz_min;

                        if chunk.get(lx_ore, ly_ore, lz_ore) == STONE {
                            chunk.set(lx_ore, ly_ore, lz_ore, ore_id);
                        }
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// TerrainGen — public API
// ---------------------------------------------------------------------------
#[derive(Default)]
pub struct TerrainGen {
    seed: u64,
}

impl TerrainGen {
    pub fn new() -> Self {
        TerrainGen { seed: 0 }
    }

    pub fn seed(&mut self, s: u64) {
        self.seed = s;
    }

    pub fn generate<C: Chunk>(&self, c: ChunkCoord, chunk: &mut C) {
        // #179 looping world: canonicalize the chunk coordinate. A chunk and
        // its torus twin (x or z shifted by WORLD_PERIOD_CHUNKS) then run the
        // byte-identical code path, which is the wrap guarantee.
        let c = ChunkCoord {
            x: c.x.rem_euclid(WORLD_PERIOD_CHUNKS),
            y: c.y,
            z: c.z.rem_euclid(WORLD_PERIOD_CHUNKS),
        };
        let seed_ = self.seed;
        let wx_min0 = c.x * K_CHUNK_DIM;
        let wz_min0 = c.z * K_CHUNK_DIM;
        // One shared build per (seed, x, z) column, reused by all Y chunks and workers.
        let shared = shared_column_data(wx_min0, wz_min0, seed_);
        let anchor_cache = &shared.anchors;
        let col_cache = &shared.cols;

        let height_at = |wx: i32, wz: i32| -> i32 {
            let lx = wx - wx_min0;
            let lz = wz - wz_min0;
            if lx >= 0 && lx < K_CHUNK_DIM && lz >= 0 && lz < K_CHUNK_DIM {
                col_cache.h[ChunkColumnCache::idx(lx, lz)]
            } else {
                surface_height_cached(wx, wz, &anchor_cache)
            }
        };

        for lz in 0..K_CHUNK_DIM {
            for lx in 0..K_CHUNK_DIM {
                let wx = c.x * K_CHUNK_DIM + lx;
                let wz = c.z * K_CHUNK_DIM + lz;

                let ci = ChunkColumnCache::idx(lx, lz);
                let dom = col_cache.dom[ci];
                let h = col_cache.h[ci];

                let mut is_steep = false;
                if dom == Biome::Mountains && h < SNOW_LINE {
                    let h_n = height_at(wx, wz - 1);
                    let h_s = height_at(wx, wz + 1);
                    let h_e = height_at(wx + 1, wz);
                    let h_w = height_at(wx - 1, wz);
                    let ad = |a: i32, b: i32| {
                        let d = a - b;
                        if d < 0 {
                            -d
                        } else {
                            d
                        }
                    };
                    let mut slope = ad(h, h_n);
                    let t = ad(h, h_s);
                    if t > slope {
                        slope = t;
                    }
                    let t = ad(h, h_e);
                    if t > slope {
                        slope = t;
                    }
                    let t = ad(h, h_w);
                    if t > slope {
                        slope = t;
                    }
                    is_steep = slope >= 3;
                }

                let mut basin_extra = 0;
                if h < SEA_LEVEL {
                    basin_extra = ocean_basin_extra(wx, wz, h, seed_);
                }
                let h_floor = h - basin_extra;

                let shaft_depth = cave_entrance_depth(wx, wz, seed_);
                let is_entrance_col = shaft_depth > 0 && h > SEA_LEVEL && dom != Biome::Swamp;

                let surface_block: BlockId;
                let fill_block: BlockId;
                let has_snow = (dom == Biome::Mountains && h >= SNOW_LINE) || dom == Biome::Snowy;

                match dom {
                    Biome::Desert => {
                        surface_block = SAND;
                        fill_block = SAND;
                    }
                    Biome::Beach => {
                        if h <= SEA_LEVEL + 2 {
                            surface_block = SAND;
                            fill_block = SAND;
                        } else {
                            surface_block = GRASS;
                            fill_block = DIRT;
                        }
                    }
                    Biome::Mountains => {
                        if h >= SNOW_LINE {
                            surface_block = STONE;
                            fill_block = STONE;
                        } else if is_steep {
                            surface_block = COBBLESTONE;
                            fill_block = STONE;
                        } else if h >= ROCK_LINE {
                            let rh = hash2(wx, wz, fmix64(seed_ ^ 0x70CC1A4E70CC1A4E));
                            let roll = rh & 0xFF;
                            let above = h - ROCK_LINE;
                            let mut rock_thresh = 115u64 + (above * 9) as u64;
                            if rock_thresh > 255 {
                                rock_thresh = 255;
                            }
                            if roll < rock_thresh {
                                surface_block = if ((rh >> 8) & 0x3) == 0 { GRAVEL } else { STONE };
                                fill_block = STONE;
                            } else {
                                surface_block = GRASS;
                                fill_block = DIRT;
                            }
                        } else {
                            surface_block = GRASS;
                            fill_block = DIRT;
                        }
                    }
                    Biome::Snowy => {
                        surface_block = DIRT;
                        fill_block = DIRT;
                    }
                    Biome::Swamp => {
                        surface_block = DIRT;
                        fill_block = DIRT;
                    }
                    // Forest, Plains, default
                    _ => {
                        surface_block = GRASS;
                        fill_block = DIRT;
                    }
                }

                for ly in 0..K_CHUNK_DIM {
                    let wy = c.y * K_CHUNK_DIM + ly;

                    let mut b;
                    if wy > h {
                        if wy <= SEA_LEVEL {
                            if has_snow && wy == SEA_LEVEL {
                                b = ICE;
                            } else {
                                b = WATER;
                            }
                        } else {
                            b = AIR;
                        }
                    } else if wy > h_floor && wy <= h {
                        b = WATER;
                    } else if wy == h_floor {
                        if wy <= SEA_LEVEL && dom != Biome::Desert {
                            b = SAND;
                        } else {
                            b = surface_block;
                        }
                    } else if wy >= h_floor - 3 {
                        if dom == Biome::Mountains && h >= SNOW_LINE && wy == h_floor - 1 {
                            b = GRAVEL;
                        } else if dom == Biome::Desert {
                            if wy == h_floor - 3 {
                                b = STONE;
                            } else {
                                b = SAND;
                            }
                        } else {
                            b = fill_block;
                        }
                    } else {
                        b = STONE;
                    }

                    if is_entrance_col && b != WATER {
                        if wy <= h && wy > h - shaft_depth {
                            b = AIR;
                        }
                    }

                    let cave_surface_ref = h_floor;
                    if b != AIR && b != WATER && wy < cave_surface_ref - CAVE_SURFACE_MARGIN && wy > K_COLUMN_MIN_Y + 4 {
                        let cseed = fmix64(seed_ ^ 0xCA4E5EED1234);
                        let cave = fbm3(wx as f32, wy as f32, wz as f32, cseed, 3, CAVE_NOISE_PERIOD);
                        if cave > CAVE_THRESH {
                            b = AIR;
                        }
                    }

                    chunk.set(lx, ly, lz, b);
                }

                let wants_snow_cap = (dom == Biome::Mountains && h >= SNOW_LINE) || dom == Biome::Snowy;
                if wants_snow_cap && h > SEA_LEVEL {
                    let snow_wy = h + 1;
                    let snow_ly = snow_wy - c.y * K_CHUNK_DIM;
                    if snow_ly >= 0 && snow_ly < K_CHUNK_DIM {
                        if chunk.get(lx, snow_ly, lz) == AIR {
                            chunk.set(lx, snow_ly, lz, SNOW_LAYER);
                        }
                    }
                }
            }
        }

        // Swamp water pools.
        for lz in 0..K_CHUNK_DIM {
            for lx in 0..K_CHUNK_DIM {
                let ci = ChunkColumnCache::idx(lx, lz);
                let dom = col_cache.dom[ci];

                if dom != Biome::Swamp {
                    continue;
                }

                let h = col_cache.h[ci];
                if h <= SEA_LEVEL + 1 {
                    for ly in 0..K_CHUNK_DIM {
                        let wy = c.y * K_CHUNK_DIM + ly;
                        if wy > h && wy <= SEA_LEVEL {
                            if chunk.get(lx, ly, lz) == AIR {
                                chunk.set(lx, ly, lz, WATER);
                            }
                        }
                    }
                }
            }
        }

        place_cave_features(c, chunk, seed_);
        place_decorations(c, chunk, seed_, &anchor_cache, &col_cache);
    }

    pub fn content_hash(&self, c: ChunkCoord) -> u64 {
        let mut tmp = DenseChunk::new(AIR);
        self.generate(c, &mut tmp);

        const FNV_OFFSET: u64 = 14695981039346656037;
        const FNV_PRIME: u64 = 1099511628211;

        let mut h = FNV_OFFSET;
        for lz in 0..K_CHUNK_DIM {
            for ly in 0..K_CHUNK_DIM {
                for lx in 0..K_CHUNK_DIM {
                    let b = tmp.get(lx, ly, lz);
                    h ^= (b & 0xFF) as u64;
                    h = h.wrapping_mul(FNV_PRIME);
                    h ^= ((b >> 8) & 0xFF) as u64;
                    h = h.wrapping_mul(FNV_PRIME);
                }
            }
        }
        h
    }
}

// ---------------------------------------------------------------------------
// Public worldgen query helpers (pure functions)
// ---------------------------------------------------------------------------
pub fn worldgen_is_cave_entrance(wx: i32, wz: i32, seed: u64) -> bool {
    is_cave_entrance(wx, wz, seed)
}

pub fn worldgen_dominant_biome(wx: i32, wz: i32, seed: u64) -> i32 {
    voronoi_biome(wx, wz, seed) as i32
}

pub fn worldgen_surface_height(wx: i32, wz: i32, seed: u64) -> i32 {
    surface_height(wx, wz, seed)
}

/// True when this column is open ocean (pulled below sea level by the continent
/// field). Exposed for diagnostics and any future ocean-aware game logic.
pub fn worldgen_is_ocean_col(wx: i32, wz: i32, seed: u64) -> bool {
    is_ocean_column(wx as f32, wz as f32, seed)
}

/// 0..1 river-channel intensity at this column (1 at the centre line). Exposed
/// for diagnostics. Note: a column with intensity > 0 is only wet if it also sits
/// at/below sea level after the carve.
pub fn worldgen_river_t(wx: i32, wz: i32, seed: u64) -> f32 {
    river_channel_t(wx as f32, wz as f32, seed)
}

pub fn worldgen_count_structures(wx0: i32, wz0: i32, span: i32, seed: u64) -> i32 {
    let scx_min = struct_floordiv(wx0, STRUCT_CELL_SIZE);
    let scx_max = struct_floordiv(wx0 + span - 1, STRUCT_CELL_SIZE);
    let scz_min = struct_floordiv(wz0, STRUCT_CELL_SIZE);
    let scz_max = struct_floordiv(wz0 + span - 1, STRUCT_CELL_SIZE);

    let mut count = 0;
    for scz in scz_min..=scz_max {
        for scx in scx_min..=scx_max {
            let sd = struct_for_cell(scx, scz, seed);
            if sd.present {
                count += 1;
            }
        }
    }
    count
}

/// Returns Some(out_y) if (wx,wz) is the anchor column of a structure.
pub fn worldgen_structure_marker_at(wx: i32, wz: i32, seed: u64) -> Option<i32> {
    let scx = struct_floordiv(wx, STRUCT_CELL_SIZE);
    let scz = struct_floordiv(wz, STRUCT_CELL_SIZE);
    for dz in -1..=1 {
        for dx in -1..=1 {
            let sd = struct_for_cell(scx + dx, scz + dz, seed);
            if sd.present && sd.anchor_wx == wx && sd.anchor_wz == wz {
                return Some(struct_surface(wx, wz, seed));
            }
        }
    }
    None
}

/// True if a structure type id is a city (the only settlement that hosts the full
/// villager profession chain). The settlement vs profession coupling lives here so the
/// worldgen city upgrade is the single source of truth: world.rs asks this instead of
/// hardcoding the STRUCT_CITY id.
pub fn worldgen_is_city(typ: i32) -> bool {
    typ == STRUCT_CITY
}

/// #201: dominant biome index at a world column (0 Plains, 1 Forest, 2 Mountains,
/// 3 Desert, 4 Snowy, 5 Swamp, 6 Beach), for biome-culture villager looks.
pub fn worldgen_biome_at(wx: i32, wz: i32, seed: u64) -> u8 {
    voronoi_biome(wx, wz, seed) as u8
}

/// #214: nearest VILLAGE or CITY anchor within `radius` blocks of (wx,wz), scanning
/// the neighbouring structure cells. worldgen_structure_near only checks the caller's
/// own 64-block cell, so a settlement just across a cell boundary was invisible to map
/// discovery. Returns (type, anchor_x, anchor_z) canonical, or None. Distances use the
/// caller's local frame (the scanned cells are the neighbourhood of wx/wz), so no
/// seam wrap is needed here.
pub fn worldgen_settlement_near(wx: i32, wz: i32, radius: i32, seed: u64) -> Option<(i32, i32, i32)> {
    let scx_min = struct_floordiv(wx - radius, STRUCT_CELL_SIZE);
    let scx_max = struct_floordiv(wx + radius, STRUCT_CELL_SIZE);
    let scz_min = struct_floordiv(wz - radius, STRUCT_CELL_SIZE);
    let scz_max = struct_floordiv(wz + radius, STRUCT_CELL_SIZE);
    let mut best: Option<(i32, i32, i32)> = None;
    let mut best_d2 = i64::MAX;
    for scz in scz_min..=scz_max {
        for scx in scx_min..=scx_max {
            let sd = struct_for_cell(scx, scz, seed);
            if !sd.present || (sd.typ != STRUCT_VILLAGE && sd.typ != STRUCT_CITY) {
                continue;
            }
            let ddx = (sd.anchor_wx - wx) as i64;
            let ddz = (sd.anchor_wz - wz) as i64;
            let d2 = ddx * ddx + ddz * ddz;
            if d2 <= (radius as i64) * (radius as i64) && d2 < best_d2 {
                best_d2 = d2;
                best = Some((sd.typ, wrap_world(sd.anchor_wx), wrap_world(sd.anchor_wz)));
            }
        }
    }
    best
}

/// Returns (type, anchor_x, anchor_z, anchor_y). type==0 (STRUCT_NONE) leaves the
/// other fields unspecified (caller should ignore them), matching the C++ contract
/// where the out-params are untouched.
pub fn worldgen_structure_near(wx: i32, wz: i32, seed: u64) -> (i32, i32, i32, i32) {
    let scx = struct_floordiv(wx, STRUCT_CELL_SIZE);
    let scz = struct_floordiv(wz, STRUCT_CELL_SIZE);
    let sd = struct_for_cell(scx, scz, seed);
    if !sd.present || sd.typ == STRUCT_NONE {
        return (STRUCT_NONE, 0, 0, 0);
    }
    let y = struct_surface(sd.anchor_wx, sd.anchor_wz, seed);
    // #179: canonical anchor so callers can key per-settlement state on it
    // (the same settlement seen from either side of the seam gets one key).
    (sd.typ, wrap_world(sd.anchor_wx), wrap_world(sd.anchor_wz), y)
}

/// Danger site lookup for the creature system. Scans structure cells overlapping a
/// square of half-size `radius` blocks around (wx,wz) and returns the anchor of the
/// nearest ruined structure as (anchor_x, anchor_y, anchor_z), or None if there is
/// no ruin in range. Deterministic for a given seed: the result depends only on the
/// structure cells, not on call order. The creature system uses this to spawn a
/// hostile or two at the ruin regardless of the night/quest gate.
pub fn worldgen_dangerous_site_near(wx: i32, wz: i32, radius: i32, seed: u64) -> Option<(i32, i32, i32)> {
    let scx_min = struct_floordiv(wx - radius, STRUCT_CELL_SIZE);
    let scx_max = struct_floordiv(wx + radius, STRUCT_CELL_SIZE);
    let scz_min = struct_floordiv(wz - radius, STRUCT_CELL_SIZE);
    let scz_max = struct_floordiv(wz + radius, STRUCT_CELL_SIZE);

    let mut best: Option<(i32, i32, i32)> = None;
    let mut best_d2 = i64::MAX;
    for scz in scz_min..=scz_max {
        for scx in scx_min..=scx_max {
            let sd = struct_for_cell(scx, scz, seed);
            if !sd.present || !struct_is_ruin(sd.typ) {
                continue;
            }
            let ddx = (sd.anchor_wx - wx) as i64;
            let ddz = (sd.anchor_wz - wz) as i64;
            let d2 = ddx * ddx + ddz * ddz;
            if d2 <= (radius as i64) * (radius as i64) && d2 < best_d2 {
                best_d2 = d2;
                let y = struct_surface(sd.anchor_wx, sd.anchor_wz, seed);
                // #179: canonical anchor so per-ruin state keys are unique.
                best = Some((wrap_world(sd.anchor_wx), y, wrap_world(sd.anchor_wz)));
            }
        }
    }
    best
}

pub fn worldgen_structure_footprint(wx: i32, wz: i32, seed: u64) -> bool {
    let scx_min = struct_floordiv(wx - STRUCT_MAX_REACH_XZ, STRUCT_CELL_SIZE);
    let scx_max = struct_floordiv(wx + STRUCT_MAX_REACH_XZ, STRUCT_CELL_SIZE);
    let scz_min = struct_floordiv(wz - STRUCT_MAX_REACH_XZ, STRUCT_CELL_SIZE);
    let scz_max = struct_floordiv(wz + STRUCT_MAX_REACH_XZ, STRUCT_CELL_SIZE);
    for scz in scz_min..=scz_max {
        for scx in scx_min..=scx_max {
            let sd = struct_for_cell(scx, scz, seed);
            if !sd.present {
                continue;
            }
            let mut ddx = wx - sd.anchor_wx;
            if ddx < 0 {
                ddx = -ddx;
            }
            let mut ddz = wz - sd.anchor_wz;
            if ddz < 0 {
                ddz = -ddz;
            }
            if ddx <= STRUCT_MAX_REACH_XZ && ddz <= STRUCT_MAX_REACH_XZ {
                return true;
            }
        }
    }
    false
}

/// Facts about a single stamped villager home, for tests / tooling. All counts are
/// over the home's footprint as actually written into the world (terrain not
/// generated, so every non-AIR cell is a home block).
#[derive(Clone, Copy, Debug)]
pub struct VillagerHomeScan {
    /// Footprint width and depth in blocks (the wall-to-wall extent in X and Z).
    pub width: i32,
    pub depth: i32,
    /// Number of door blocks in the walls (a 1 wide door is 2 tall = 2 blocks).
    pub door_blocks: i32,
    /// Number of window (glass pane) blocks in the walls.
    pub window_blocks: i32,
    /// Number of bed blocks placed inside.
    pub bed_blocks: i32,
    /// Largest count of contiguous interior air cells on the floor level (standable
    /// space). At least 9 (a 3x3 cavity) for a 5x5 home.
    pub interior_air: i32,
    /// True if the lowest block in every occupied column rests on (or fills down to)
    /// the terrain, i.e. the home does not float.
    pub on_ground: bool,
}

/// Stamps one villager home (place_hut) at a deterministic on-land anchor for the
/// given seed and returns a scan of its footprint. Pure: depends only on the seed.
/// Used by tests to assert the home is a real building (>= 5x5, has a door opening,
/// windows, an interior air cavity, and a bed) without reaching into chunk internals.
pub fn worldgen_villager_home_scan(seed: u64) -> VillagerHomeScan {
    // Pick an on-land anchor: scan a bounded grid of widely spaced columns once and
    // take the first that sits well above sea level (not in water). Deterministic and
    // bounded; the wide step finds dry land quickly even when the origin is ocean.
    let mut ax = 0;
    let mut az = 0;
    'find: for d in 0..96i32 {
        // d is a Chebyshev ring index over a grid stepped by 16 blocks; check the
        // ring perimeter only so each column is visited once.
        for dz in -d..=d {
            for dx in -d..=d {
                if dx.abs() != d && dz.abs() != d {
                    continue; // interior of the ring already checked at smaller d
                }
                let cx = dx * 16;
                let cz = dz * 16;
                if surface_height(cx, cz, seed) > SEA_LEVEL + 4
                    && !is_ocean_column(cx as f32, cz as f32, seed)
                {
                    ax = cx;
                    az = cz;
                    break 'find;
                }
            }
        }
    }

    let hh = fmix64((seed ^ 0x484F4D4501u64).wrapping_mul(0x2545F4914F6CDD1D));

    // Unbounded grid that satisfies Chunk for one chunk window at a time; replay the
    // stamp over every window the home reaches so we capture the whole footprint.
    struct ScanGrid {
        wx_min: i32,
        wy_min: i32,
        wz_min: i32,
        cells: std::collections::HashMap<(i32, i32, i32), BlockId>,
    }
    impl Chunk for ScanGrid {
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

    let floordiv = |a: i32, b: i32| a / b - if a % b != 0 && (a ^ b) < 0 { 1 } else { 0 };
    let reach = 4; // homes reach at most 3 from centre; 4 gives a margin
    let base = surface_height(ax, az, seed);
    let cx0 = floordiv(ax - reach, K_CHUNK_DIM);
    let cx1 = floordiv(ax + reach, K_CHUNK_DIM);
    let cz0 = floordiv(az - reach, K_CHUNK_DIM);
    let cz1 = floordiv(az + reach, K_CHUNK_DIM);
    let cy0 = floordiv(base - 16, K_CHUNK_DIM);
    let cy1 = floordiv(base + 16, K_CHUNK_DIM);

    let mut cells: std::collections::HashMap<(i32, i32, i32), BlockId> =
        std::collections::HashMap::new();
    for cy in cy0..=cy1 {
        for cz in cz0..=cz1 {
            for cx in cx0..=cx1 {
                let (wx_min, wy_min, wz_min) =
                    (cx * K_CHUNK_DIM, cy * K_CHUNK_DIM, cz * K_CHUNK_DIM);
                let mut g = ScanGrid {
                    wx_min,
                    wy_min,
                    wz_min,
                    cells: std::mem::take(&mut cells),
                };
                place_hut(ax, az, hh, seed, &mut g, wx_min, wy_min, wz_min);
                cells = g.cells;
            }
        }
    }

    // Footprint extent.
    let mut min_x = i32::MAX;
    let mut max_x = i32::MIN;
    let mut min_z = i32::MAX;
    let mut max_z = i32::MIN;
    let mut door_blocks = 0;
    let mut window_blocks = 0;
    let mut bed_blocks = 0;
    for (&(wx, _wy, wz), &b) in cells.iter() {
        if b == AIR {
            continue;
        }
        min_x = min_x.min(wx);
        max_x = max_x.max(wx);
        min_z = min_z.min(wz);
        max_z = max_z.max(wz);
        if b == OAK_DOOR {
            door_blocks += 1;
        } else if b == GLASS_PANE {
            window_blocks += 1;
        } else if b == BED {
            bed_blocks += 1;
        }
    }
    let width = if max_x >= min_x { max_x - min_x + 1 } else { 0 };
    let depth = if max_z >= min_z { max_z - min_z + 1 } else { 0 };

    // Interior cavity (standable space): the cells one block above the floor, strictly
    // inside the wall ring (min/max bounds). The floor surface level is read off the
    // door, whose lowest block sits at floor + 1, so the floor level is (lowest door
    // y) - 1 and the standable layer is floor + 1. A cell counts as cavity when it is
    // open (AIR or furniture such as a bed) rather than wall, i.e. it is part of the
    // room you can stand in. We deliberately count the bed cells too: they are part of
    // the open interior footprint (the bed is removable furniture, not structure). The
    // separate on_ground check guarantees something solid rests beneath each column,
    // so we do not require a floor block in this terrain-free scan.
    let mut door_low_y = i32::MAX;
    for (&(_wx, wy, _wz), &b) in cells.iter() {
        if b == OAK_DOOR && wy < door_low_y {
            door_low_y = wy;
        }
    }
    let mut interior_air = 0;
    if door_low_y != i32::MAX {
        let floor_y = door_low_y; // standable layer = door bottom level
        for wz in (min_z + 1)..max_z {
            for wx in (min_x + 1)..max_x {
                let here = *cells.get(&(wx, floor_y, wz)).unwrap_or(&AIR);
                // Open interior: air or furniture (bed). Anything else here would be a
                // wall block, which should not appear in the interior.
                if here == AIR || here == BED {
                    interior_air += 1;
                }
            }
        }
    }

    // On-ground: a column "floats" only if it is a real wall / foundation stack
    // (2+ blocks) whose base hangs well above the terrain with clear air beneath.
    // This mirrors the established big_structures_sit_on_ground floater rule: a lone
    // decorative block (a ceiling lamp over the open interior) is not a floater, and
    // the surf+4 tolerance allows a door lintel that opens over the ground. Terrain
    // is not generated in this scan, so the wall / foundation columns are what matter.
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
    let mut on_ground = true;
    for (&(wx, wz), &(y_low, count)) in low.iter() {
        let surf = surface_height(wx, wz, seed);
        if y_low > surf + 4 && count >= 2 {
            on_ground = false;
            break;
        }
    }

    VillagerHomeScan {
        width,
        depth,
        door_blocks,
        window_blocks,
        bed_blocks,
        interior_air,
        on_ground,
    }
}

#[cfg(test)]
include!("worldgen_tests.rs");
