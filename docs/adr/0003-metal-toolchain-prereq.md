# ADR 0003 — Metal shader compilation strategy

Status: Accepted (Phase 0)

## Context
The offline Metal toolchain (`xcrun metal`/`metallib`) is a separately
downloaded Xcode component and was **not** present on the dev box at Phase 0
(`xcodebuild -downloadComponent MetalToolchain`). The spec §5 lists a compiled
`.metallib` step for `/shaders`.

## Decision
- **M0/Phase 0 and prototyping:** compile shaders **at runtime** via
  `MTLDevice.makeLibrary(source:options:)`, which uses the in-OS Metal
  framework and needs no offline toolchain. The M0 clear-frame needs no custom
  shader at all.
- **Track E onward:** precompile `/shaders/*.metal` → `.metallib` as a build
  step in `build.sh`, bundled into the `.app`, for faster startup and so the
  shipped app does not compile shaders on the kids' Airs. This requires the
  Metal toolchain on the **build** box only:
  `xcodebuild -downloadComponent MetalToolchain`.

## Consequences
- Phase 0 unblocked without the large toolchain download.
- `build.sh` gains a `.metallib` step when Track E starts; documented as a
  build-box prerequisite (clients never need it).

## Breakage if wrong
Runtime shader compilation adds first-frame latency on clients — unacceptable
for the shipped product, which is exactly why Track E switches to precompiled
`.metallib`. The runtime path stays available as a dev fallback.
