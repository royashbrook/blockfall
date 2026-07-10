#![allow(clippy::too_many_arguments)]
#![allow(clippy::needless_range_loop)]

// ============================================================================
// Blockfall world generation.
//
// These files are included into one Rust module so the deterministic generation
// helpers stay private and shared without a wide visibility/import refactor.
// ============================================================================
include!("worldgen/common.rs");
include!("worldgen/cave_entrances.rs");
include!("worldgen/biomes.rs");
include!("worldgen/terrain.rs");
include!("worldgen/columns.rs");
include!("worldgen/flora.rs");
include!("worldgen/structures.rs");
include!("worldgen/underground.rs");
include!("worldgen/decorations.rs");
include!("worldgen/api.rs");

#[cfg(test)]
include!("worldgen/tests.rs");
