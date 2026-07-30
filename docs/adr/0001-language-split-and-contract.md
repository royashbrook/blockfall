# ADR 0001 — Language split and the C ABI contract

Status: Superseded in part by ADR 0008

## Context
Blockfall needs a high-performance simulation/world/meshing/net core and a
native Apple shell (window, Metal, input, HUD). Spec §4.1 fixes the split.

## Decision
- **Core** (sim, world, meshing, net, jobs, gameplay) was originally **C++23**.
  It has since been replaced by Rust `bfcore`; ADR 0008 records the current
  build and distribution decision.
- **App shell** (window/event loop, Metal setup, input, HUD/UI) → native
  **Swift + MetalKit**: AppKit on macOS and UIKit on iPadOS.
- The **only** boundary is a pure **C ABI**, `contract/engine_c_api.h`. No
  Rust-native types cross into Swift.
- ABI is versioned (`BF_ABI_VERSION`); the app refuses to run on a mismatch.

## Consequences
- Swift never owns world state; it injects input and consumes render+HUD
  snapshots (server-authoritative even single-player, spec §4.7).
- UMA zero-copy: the renderer (Swift) owns MTLBuffers; the engine writes mesh
  bytes into them via a registered `bf_gpu_allocator` (see threading.md).
- Changing the ABI or internal interface layout requires a new ADR.

## Breakage if wrong
A leaky boundary (Rust-native types in Swift) would couple the two toolchains
and break clean linkage; the versioned ABI guards against silent drift.
