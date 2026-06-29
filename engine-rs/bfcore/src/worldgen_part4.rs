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
                let gpatch = value_noise2(wx as f32 * 0.085, wz as f32 * 0.085, pseed ^ 0x6772ABCD);
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
                    if surf == SAND && roll < 7 {
                        plant = CACTUS_PLANT;
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

                if plant == AIR && roll3 >= 249 && (surf == GRASS || surf == DIRT || surf == STONE || surf == SAND) {
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

                if (kh & 0xFF) >= 56 {
                    continue;
                }

                let mut strand = 1 + ((kh >> 8) % 3) as i32;
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
        const ORE_CELL_SIZE: i32 = 7;
        const ORE_VEIN_REACH: i32 = 4;

        const COAL_Y_MAX: i32 = -2;
        const COPPER_Y_MAX: i32 = -8;
        const IRON_Y_MAX: i32 = -14;
        const CRYSTAL_Y_MAX: i32 = -24;

        const COAL_THRESH: u64 = 38;
        const COPPER_THRESH: u64 = 20;
        const IRON_THRESH: u64 = 13;
        const CRYSTAL_THRESH: u64 = 3;

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
                    let h = hash3(cx_cell, cy_cell, cz_cell, ore_seed);
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
        let seed_ = self.seed;
        let wx_min0 = c.x * K_CHUNK_DIM;
        let wz_min0 = c.z * K_CHUNK_DIM;
        let anchor_cache = build_anchor_cache(wx_min0, wz_min0, seed_);
        let col_cache = build_column_cache(wx_min0, wz_min0, seed_, &anchor_cache);

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
                        let cave = fbm3(wx as f32, wy as f32, wz as f32, cseed, 3, 1.0 / 16.0);
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
    (sd.typ, sd.anchor_wx, sd.anchor_wz, y)
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
                best = Some((sd.anchor_wx, y, sd.anchor_wz));
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
                if chunks_checked >= 8 {
                    break 'scan;
                }
            }
        }

        assert!(desert_columns > 0, "sample set no longer covers desert columns");
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
        assert_eq!((ax, az), (rx, rz), "danger marker did not point at the ruin anchor");
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
        // land. The naked-trunk invariant is unchanged.
        let (naked, total) = scan_naked_trunks(SEED, -22, 22, -22, 22);
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
        let samples = [
            (11u64, -20, -40, STRUCT_CABIN),
            (11u64, 36, -40, STRUCT_KEEP),
            (11u64, -25, -40, STRUCT_TALL_TOWER),
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
}
