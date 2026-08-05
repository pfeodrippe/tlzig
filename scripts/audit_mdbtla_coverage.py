#!/usr/bin/env python3
"""Verify upstream MDBTLA cfg coverage in the benchmark manifest."""

from __future__ import annotations

import re
import sys
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
UPSTREAM_ROOT = REPO / "vendor" / "MDBTLA"
BENCHMARK = REPO / "scripts" / "benchmark.zig"

# These cfgs are rejected by TLC because the TLA+ module declares Timestamps
# but the cfg does not assign it. Keep this list small and evidence-backed.
TLC_INVALID_CFGS = {
    "vendor/MDBTLA/MultiShardTxn/MultiShardTxn.cfg",
    "vendor/MDBTLA/MultiShardTxn/models/MultiShardTxn_RC.cfg",
}

# TLC warns that symmetry reduction is unsound during liveness checking. These
# upstream configurations are covered by equivalent symmetry-free benchmark
# configs so the result is evidence for the actual temporal semantics.
SOUND_TEMPORAL_BASELINES = {
    "vendor/MDBTLA/SingleShardTxn/ShardTxn.cfg":
        "benchmark_configs/MDBTLA/SingleShardTxn/ShardTxn_no_sym.cfg",
}


def posix(path: Path) -> str:
    return path.relative_to(REPO).as_posix()


def main() -> int:
    upstream_cfgs = sorted(posix(path) for path in UPSTREAM_ROOT.rglob("*.cfg"))
    benchmark_source = BENCHMARK.read_text(encoding="utf-8")
    benchmark_cfgs = set(
        match.group(1)
        for match in re.finditer(r'\.cfg\s*=\s*"([^"]+)"', benchmark_source)
    )

    missing = [
        cfg for cfg in upstream_cfgs
        if cfg not in benchmark_cfgs
        and SOUND_TEMPORAL_BASELINES.get(cfg) not in benchmark_cfgs
        and cfg not in TLC_INVALID_CFGS
    ]
    stale_invalid = sorted(TLC_INVALID_CFGS - set(upstream_cfgs))

    print(f"upstream MDBTLA cfgs: {len(upstream_cfgs)}")
    print(
        "benchmark-covered upstream cfgs: "
        f"{sum(cfg in benchmark_cfgs for cfg in upstream_cfgs)}"
    )
    print(f"TLC-invalid upstream cfgs: {len(TLC_INVALID_CFGS)}")
    print(
        "sound temporal baseline substitutions: "
        f"{len(SOUND_TEMPORAL_BASELINES)}"
    )

    if missing:
        print("\nmissing benchmark coverage:")
        for cfg in missing:
            print(f"  {cfg}")

    if stale_invalid:
        print("\nstale TLC-invalid entries:")
        for cfg in stale_invalid:
            print(f"  {cfg}")

    if missing or stale_invalid:
        return 1

    print("MDBTLA upstream cfg coverage is complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
