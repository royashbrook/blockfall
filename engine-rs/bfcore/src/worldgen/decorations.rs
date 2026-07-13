// ===========================================================================
// Decoration pass: trees, plants, deadwood, structures, and ore pockets.
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

                // #280: the height field is the pre-carve surface. Cave entrances
                // remove that support before decorations run, so never root a tree
                // in one of their open columns.
                if cave_entrance_depth(td.root_wx, td.root_wz, seed) > 0 {
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
                // Dense patches should read as pockets of vegetation, not a solid
                // carpet. The renderer supplies silhouette variety; generation
                // leaves enough open ground for paths and terrain to remain legible.
                let gt: u64 = if gpatch > 0.62 { 92 } else { 12 };

                let mut plant = AIR;

                if dom == Biome::Forest {
                    if surf == GRASS {
                        if roll < gt {
                            plant = TALL_GRASS;
                        } else if roll < gt + 6 {
                            plant = FLOWER_RED;
                        } else if roll < gt + 12 {
                            plant = FLOWER_YELLOW;
                        } else if roll < gt + 16 {
                            plant = MUSHROOM;
                        } else if roll < gt + 19 {
                            plant = BERRY_BUSH;
                        } else if roll < gt + 22 {
                            plant = FALLEN_STICK;
                        }
                    } else if surf == DIRT {
                        if roll2 < 24 {
                            plant = MUSHROOM;
                        } else if roll2 < 34 {
                            plant = TALL_GRASS;
                        } else if roll2 < 40 {
                            plant = FALLEN_STICK;
                        }
                    }
                } else if dom == Biome::Swamp {
                    if surf == GRASS || surf == DIRT {
                        if roll < gt {
                            plant = TALL_GRASS;
                        } else if roll < gt + 10 {
                            plant = MUSHROOM;
                        } else if roll < gt + 15 {
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
                        } else if roll < gt + 8 {
                            plant = FLOWER_RED;
                        } else if roll < gt + 16 {
                            plant = FLOWER_YELLOW;
                        } else if roll < gt + 20 {
                            plant = MUSHROOM;
                        } else if roll < gt + 23 {
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
                        if roll < 14 {
                            plant = TALL_GRASS;
                        } else if roll < 20 {
                            plant = FLOWER_RED;
                        } else if roll < 26 {
                            plant = FLOWER_YELLOW;
                        } else if roll < 29 {
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
