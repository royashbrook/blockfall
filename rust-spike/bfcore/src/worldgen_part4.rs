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
                    if surf == SAND && roll < 10 {
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

                if roll < 42 {
                    chunk.set(lx, ly_above, lz, MUSHROOM);
                } else if roll < 70 {
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

    // The coastal gate: classify_climate_excluding never returns the excluded biome.
    #[test]
    fn exclude_skips_biome() {
        // Beach-ish climate, excluding Beach, must pick something else.
        let b = classify_climate_excluding(0.78, 0.55, Biome::Beach as i32);
        assert_ne!(b, Biome::Beach as i32);
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
        let (naked, total) = scan_naked_trunks(SEED, -12, 12, -12, 12);
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
}
