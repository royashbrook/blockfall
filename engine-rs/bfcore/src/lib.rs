//! bfcore: Rust port of the Blockfall blockcore engine.
//!
//! Ported in dependency order, each module parity-gated against the C++ engine
//! (chunk + worldgen + mesher are byte-exact; content is record-exact). The app
//! stays Swift/Metal; only the engine moves, behind the frozen C ABI.

pub mod abi;
pub mod chunk;
pub mod content;
pub mod creature_ai;
pub mod ffi;
pub mod inventory;
pub mod jobs;
pub mod lighting;
pub mod mesher;
pub mod net;
pub mod session;
pub mod store;
pub mod types;
pub mod world;
pub mod worldgen;
