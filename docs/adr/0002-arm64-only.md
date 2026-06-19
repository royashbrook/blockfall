# ADR 0002 — arm64-only installer (no universal binary)

Status: Accepted (Phase 0)

## Context
Spec §2 confirms both ends are Apple Silicon: dev box M4 Pro/48 GB, target
MacBook Air M1/16 GB. A universal (arm64+x86_64) binary would double build
time and bundle size for zero benefit.

## Decision
Build **arm64-only**. `CMAKE_OSX_ARCHITECTURES=arm64`; `package.sh` asserts the
binary is arm64 and rejects a universal/x86_64 slice. Metal features gated to
M1-available / macOS 14+ APIs with capability detection + fallback (spec §10).

## Consequences
- `package.sh` is simpler (no `lipo` fat-binary merge).
- The app will not run on Intel Macs — acceptable per confirmed hardware.

## Breakage if wrong
If an Intel client ever appears, this ADR must be revisited and a universal
build re-introduced; the asserting check in `package.sh` makes the constraint
explicit rather than silent.
