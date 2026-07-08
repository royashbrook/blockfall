#!/usr/bin/env python3
"""Compare two Blockfall perf JSON files from the same machine."""
import argparse
import json
import sys
from pathlib import Path


def load(path: str) -> dict:
    return json.loads(Path(path).read_text())


def pct_change(base: float, cand: float) -> float:
    if base == 0:
        return 0.0 if cand == 0 else float("inf")
    return (cand - base) / base


def check_drop(label: str, base: dict, cand: dict, key: str, max_drop: float, failures: list[str]) -> None:
    if key not in base or key not in cand:
        return
    b, c = float(base[key]), float(cand[key])
    drop = -pct_change(b, c)
    print(f"{label}: {b:.3f} -> {c:.3f} ({pct_change(b, c) * 100:+.1f}%)")
    if drop > max_drop:
        failures.append(f"{label} dropped {drop * 100:.1f}% > {max_drop * 100:.1f}%")


def check_rise(label: str, base: dict, cand: dict, key: str, max_rise: float, failures: list[str]) -> None:
    if key not in base or key not in cand:
        return
    b, c = float(base[key]), float(cand[key])
    rise = pct_change(b, c)
    print(f"{label}: {b:.3f} -> {c:.3f} ({rise * 100:+.1f}%)")
    if rise > max_rise:
        failures.append(f"{label} rose {rise * 100:.1f}% > {max_rise * 100:.1f}%")


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Fail when a candidate perf JSON regresses materially from a same-machine baseline."
    )
    ap.add_argument("baseline_json")
    ap.add_argument("candidate_json")
    ap.add_argument("--max-median-drop", type=float, default=0.12)
    ap.add_argument("--max-low-drop", type=float, default=0.25)
    ap.add_argument("--max-frame-rise", type=float, default=0.20)
    ap.add_argument("--max-gpu-rise", type=float, default=0.30)
    args = ap.parse_args()

    base = load(args.baseline_json)
    cand = load(args.candidate_json)
    failures: list[str] = []

    check_drop("fps median", base, cand, "fps_median", args.max_median_drop, failures)
    check_drop("fps 1%-low", base, cand, "fps_1pct_low", args.max_low_drop, failures)
    check_rise("frame ms", base, cand, "frame_ms_median", args.max_frame_rise, failures)
    check_rise("gpu ms", base, cand, "gpu_ms_median", args.max_gpu_rise, failures)

    if failures:
        print("PERF REGRESSION:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("perf compare OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
