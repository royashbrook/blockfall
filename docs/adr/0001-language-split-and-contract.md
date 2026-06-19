# ADR 0001 — Language split and the C ABI contract

Status: Accepted (Phase 0)

## Context
Blockfall needs a high-performance simulation/world/meshing/net core and a
native macOS shell (window, Metal, input, HUD). Spec §4.1 fixes the split.

## Decision
- **Core** (sim, world, meshing, net, jobs, gameplay) → **C++23**, built as a
  CMake static library `blockcore`.
- **App shell** (window/event loop, Metal setup, input, HUD/UI) → **Swift +
  AppKit/MetalKit**, linking `blockcore`.
- The **only** boundary is a pure **C ABI**, `contract/engine_c_api.h`. No C++
  types cross into Swift. C++ internal interfaces live in
  `contract/blockcore_interfaces.hpp` and never reach Swift.
- ABI is versioned (`BF_ABI_VERSION`); the app refuses to run on a mismatch.

## Consequences
- Swift never owns world state; it injects input and consumes render+HUD
  snapshots (server-authoritative even single-player, spec §4.7).
- UMA zero-copy: the renderer (Swift) owns MTLBuffers; the engine writes mesh
  bytes into them via a registered `bf_gpu_allocator` (see threading.md).
- Changing the ABI or internal interface layout requires a new ADR.

## Breakage if wrong
A leaky boundary (C++ types in Swift) would couple the two toolchains and break
the installer's clean linkage; the versioned ABI guards against silent drift.
