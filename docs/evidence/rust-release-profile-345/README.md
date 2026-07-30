# Rust release-profile evidence — #345

The retained release profile uses ThinLTO, one codegen unit, and abort-on-panic.
The decision was based on deterministic engine microbenchmarks plus three
20-second fixed-seed, fixed-camera Metal runs for each profile.

| Measure | Default | Tuned | Change |
| --- | ---: | ---: | ---: |
| Flat-chunk mesh average | 0.249 ms | 0.220 ms | **−11.6%** |
| Checker-chunk mesh average | 1.411 ms | 1.245 ms | **−11.8%** |
| Clean frame build average | 0.867 ms | 0.806 ms | **−7.0%** |
| Dirty frame/remesh | 2.486 ms | 2.495 ms | +0.4% |
| Metal median FPS | 151.6 | 158.6 | +4.6% |
| Metal 1%-low FPS | 109.1 | 109.8 | +0.6% |
| Metal engine p99 | 1.343 ms | 1.319 ms | −1.8% |
| Metal acquire/remesh p99 | 1.324 ms | 1.283 ms | −3.1% |
| Final macOS executable | 4,010,048 B | 3,767,456 B | **−6.0%** |

The Metal fixture's median draw counts differed by 0.5% and terrain indices by
2.8%, so the deterministic CPU cases are the strongest runtime evidence. The
three-run Metal medians show no tail-latency or 1%-low regression.

Tradeoff: an observed cold sequential build of all three Rust slices increased
from 19.61 seconds to 42.10 seconds. Incremental no-change builds remain about
0.01 seconds per slice. Intermediate static archives grew roughly 13%, but
Apple's final linked executable shrank 6% through better dead stripping.

`panic = "abort"` does not weaken an existing recovery path: unwinding a Rust
panic through Blockfall's `extern "C"` boundary is already unsupported. Tests
continue using Cargo's test panic behavior.

Raw summarized measurements are in
[`summary.json`](summary.json). After measurement, all three framework slices
passed the real Apple-linker ABI smoke test and `./ci/check.sh` passed.
