//! bfcore: Rust port of the Blockfall blockcore engine.
//!
//! Migration in progress, ported in dependency order with a parity test gating each
//! module against the C++ engine. The app stays Swift/Metal; only the engine moves,
//! behind the frozen C ABI (contract/engine_c_api.h), so it can swap in module by module.
//!
//! Ported so far: types, chunk (byte-parity with C++), inventory.

pub mod types;
pub mod chunk;
pub mod inventory;
