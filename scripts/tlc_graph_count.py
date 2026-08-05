#!/usr/bin/env python3
"""Count node records in Java TLC liveness ptrs_N files.

The format is defined by AbstractDiskGraph.addNode and
BufferedRandomAccessFile.writeLongNat in the vendored TLC source. This tool is
read-only and does not interpret nodes_N successor payloads.
"""

from __future__ import annotations

import argparse
import mmap
import pathlib
import struct
import sys
import time


FIXED_PREFIX_BYTES = 12  # state fingerprint (i64) + tableau index (i32)
SHORT_RECORD_BYTES = 16
LONG_RECORD_BYTES = 20
INT32_MAX = (1 << 31) - 1


class NodePointerNotReady(ValueError):
    pass


def i32(data: mmap.mmap, offset: int) -> int:
    return struct.unpack_from(">i", data, offset)[0]


def u32(data: mmap.mmap, offset: int) -> int:
    return struct.unpack_from(">I", data, offset)[0]


def long_nat(data: mmap.mmap, offset: int) -> tuple[int, int]:
    high = i32(data, offset)
    if high >= 0:
        return high, 4
    encoded = (high << 32) | u32(data, offset + 4)
    return -encoded, 8


def validate_record(
    data: mmap.mmap,
    offset: int,
    node_bytes: int,
    nodes_path: pathlib.Path,
) -> tuple[int, int]:
    if len(data) - offset < SHORT_RECORD_BYTES:
        raise ValueError(f"truncated record at byte {offset}")
    tableau_index = i32(data, offset + 8)
    pointer_high = i32(data, offset + FIXED_PREFIX_BYTES)
    if pointer_high < 0 and len(data) - offset < LONG_RECORD_BYTES:
        raise ValueError(f"truncated record at byte {offset}")
    pointer, pointer_bytes = long_nat(data, offset + FIXED_PREFIX_BYTES)
    record_bytes = FIXED_PREFIX_BYTES + pointer_bytes
    if pointer < 0:
        raise ValueError(f"negative node pointer {pointer} at byte {offset}")
    if pointer >= node_bytes:
        # In a live run TLC can publish the ptrs record immediately before the
        # corresponding node payload becomes visible. Re-stat only on this
        # exceptional tail path; completed or corrupt files still fail.
        for delay in (0.0, 0.01, 0.02, 0.04, 0.08):
            if delay:
                time.sleep(delay)
            node_bytes = nodes_path.stat().st_size
            if pointer < node_bytes:
                break
    if pointer >= node_bytes:
        raise NodePointerNotReady(
            f"node pointer {pointer} at byte {offset} is outside nodes file "
            f"of {node_bytes} bytes"
        )
    return tableau_index, record_bytes


def count_graph(
    ptrs_path: pathlib.Path,
    *,
    live: bool = False,
) -> tuple[int, int, int, int, int]:
    suffix = ptrs_path.name.removeprefix("ptrs_")
    nodes_path = ptrs_path.with_name(f"nodes_{suffix}")
    node_bytes = nodes_path.stat().st_size
    if node_bytes == 0:
        raise ValueError(f"empty nodes file: {nodes_path}")

    with ptrs_path.open("rb") as file:
        if ptrs_path.stat().st_size == 0:
            return 0, -1, -1, 0, 0
        with mmap.mmap(file.fileno(), 0, access=mmap.ACCESS_READ) as data:
            offset = 0
            short_records = 0
            min_tableau = INT32_MAX
            max_tableau = -(1 << 31)

            # Node offsets are append-only and monotonic. TLC switches from a
            # 4-byte to an 8-byte natural exactly once, after 2 GiB of nodes.
            while offset < len(data):
                remaining = len(data) - offset
                if remaining < SHORT_RECORD_BYTES:
                    if short_records == 0:
                        min_tableau = max_tableau = -1
                    return (
                        short_records,
                        min_tableau,
                        max_tableau,
                        remaining,
                        0,
                    )
                if (
                    i32(data, offset + FIXED_PREFIX_BYTES) < 0
                    and remaining < LONG_RECORD_BYTES
                ):
                    if short_records == 0:
                        min_tableau = max_tableau = -1
                    return (
                        short_records,
                        min_tableau,
                        max_tableau,
                        remaining,
                        0,
                    )
                try:
                    tableau_index, record_bytes = validate_record(
                        data,
                        offset,
                        node_bytes,
                        nodes_path,
                    )
                except NodePointerNotReady:
                    if not live:
                        raise
                    if short_records == 0:
                        min_tableau = max_tableau = -1
                    return (
                        short_records,
                        min_tableau,
                        max_tableau,
                        remaining % SHORT_RECORD_BYTES,
                        remaining // SHORT_RECORD_BYTES,
                    )
                min_tableau = min(min_tableau, tableau_index)
                max_tableau = max(max_tableau, tableau_index)
                if record_bytes == LONG_RECORD_BYTES:
                    break
                short_records += 1
                offset += SHORT_RECORD_BYTES

            if offset == len(data):
                return short_records, min_tableau, max_tableau, 0, 0

            remaining = len(data) - offset
            partial_bytes = remaining % LONG_RECORD_BYTES
            long_records = remaining // LONG_RECORD_BYTES

            # Validate the first and last long records. Counting the middle is
            # arithmetic because monotonic offsets cannot return to short form.
            complete_end = len(data) - partial_bytes
            for record_offset in (offset,):
                tableau_index, record_bytes = validate_record(
                    data,
                    record_offset,
                    nodes_path.stat().st_size,
                    nodes_path,
                )
                if record_bytes != LONG_RECORD_BYTES:
                    raise ValueError(
                        f"non-monotonic pointer width at byte {record_offset}"
                    )
                min_tableau = min(min_tableau, tableau_index)
                max_tableau = max(max_tableau, tableau_index)

            pending_records = 0
            while long_records > 0:
                record_offset = complete_end - LONG_RECORD_BYTES
                try:
                    tableau_index, record_bytes = validate_record(
                        data,
                        record_offset,
                        nodes_path.stat().st_size,
                        nodes_path,
                    )
                except NodePointerNotReady:
                    if not live:
                        raise
                    pending_records += 1
                    long_records -= 1
                    complete_end -= LONG_RECORD_BYTES
                    continue
                if record_bytes != LONG_RECORD_BYTES:
                    raise ValueError(
                        f"non-monotonic pointer width at byte {record_offset}"
                    )
                min_tableau = min(min_tableau, tableau_index)
                max_tableau = max(max_tableau, tableau_index)
                break

            return (
                short_records + long_records,
                min_tableau,
                max_tableau,
                partial_bytes,
                pending_records,
            )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "metadir",
        type=pathlib.Path,
        help="TLC metadir or its timestamped run subdirectory",
    )
    args = parser.parse_args()

    run_dir = args.metadir
    ptrs = sorted(run_dir.glob("ptrs_*"))
    if not ptrs:
        children = sorted(path for path in run_dir.iterdir() if path.is_dir())
        if len(children) != 1:
            parser.error("metadir must contain ptrs_N files or one run directory")
        run_dir = children[0]
        ptrs = sorted(run_dir.glob("ptrs_*"))
    if not ptrs:
        parser.error("no ptrs_N files found")

    counts: list[int] = []
    for ptrs_path in ptrs:
        try:
            (
                count,
                min_tableau,
                max_tableau,
                partial_bytes,
                pending_records,
            ) = count_graph(ptrs_path, live=True)
        except (OSError, ValueError) as error:
            print(f"{ptrs_path.name}: error: {error}", file=sys.stderr)
            return 1
        counts.append(count)
        tableau = (
            "none (-1)"
            if min_tableau == -1 and max_tableau == -1
            else f"{min_tableau}..{max_tableau}"
        )
        growing = (
            f" partial_bytes={partial_bytes}" if partial_bytes != 0 else ""
        )
        pending = (
            f" pending_records={pending_records}"
            if pending_records != 0
            else ""
        )
        print(
            f"{ptrs_path.name}: node_records={count} tableau={tableau}"
            f"{growing}{pending}"
        )

    if len(set(counts)) != 1:
        print(
            "note: property graph record counts differ while TLC is running",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
