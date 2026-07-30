# ADR 0008 — Rust core packaged as one Apple XCFramework

Status: Accepted

Issue: #344

## Context

Blockfall's simulation, world generation, meshing, networking, and gameplay
engine are Rust. Swift owns the Apple UI and Metal renderer. The macOS build
previously linked a host-only `libbfcore.a` through manual linker flags, copied
the ABI header into the Swift package, and kept an empty C source file solely
to make SwiftPM expose that header.

The iPadOS shell needs the same engine. Rust machine code still has to be
compiled for each target ABI, but separate framework products or engine
implementations would create needless packaging and integration drift.

## Decision

- `ci/build-xcframework.sh` is the single Apple-engine build entry point.
- It compiles `bfcore` for Apple Silicon macOS, iPadOS devices, and Apple
  Silicon iPad simulators.
- `xcodebuild -create-xcframework` packages those archives, the canonical
  `contract/engine_c_api.h`, and its module map as
  `app/Artifacts/CBlockcore.xcframework`.
- Swift imports one `CBlockcore` binary target on every Apple platform.
- The C ABI remains the narrow, stable language boundary. It is a calling
  convention and data contract, not a C implementation layer.
- Platform shells remain native: AppKit for the existing macOS app and
  UIKit/MetalKit for the iPadOS app.

## Consequences

- One command and one artifact replace copied headers, the empty C shim, and
  manual `-L`/`-lbfcore` flags.
- Large render arrays remain borrowed and chunk meshes remain zero-copy shared
  Metal buffers; the packaging change adds no runtime layer.
- Builders need rustup with the pinned toolchain. The script installs missing
  standard-library targets after the one-time rustup setup.
- `CBlockcore.xcframework` is generated and ignored. A source checkout must
  build it before invoking SwiftPM directly.
- The iPadOS application shell, touch/controller controls, responsive HUD,
  lifecycle checkpoints, and audio-session behavior consume the same artifact
  without changing this boundary.
- App Store metadata and distribution remain separate from engine packaging.
