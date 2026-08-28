#!/usr/bin/env python3
"""Patch the verified ADFR min-fps power-mode gate for the OnePlus 15.

The port's Composer plugin receives power mode 1 for AOD and 2 for the
interactive display.  On this build the plugin's Full-AOD flag is never
updated, so the AOD path falls through to the normal 120 Hz result.  Replace
only the flag load/check pair with a power-mode-1 check.
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


SOURCE_SHA256 = "b0816cc5afa8c508f563b81cc5644d6475052cc856acc451c893909176bfd8aa"
PATCHES = {
    0x113A4: (
        bytes.fromhex("6a3242b9"),
        bytes.fromhex("1f050071"),
        "cmp w8, #1 (AOD power mode)",
    ),
    0x113A8: (
        bytes.fromhex("ea020034"),
        bytes.fromhex("e1020054"),
        "b.ne normal path",
    ),
    0x116CC: (
        bytes.fromhex("c1f4ff54"),
        bytes.fromhex("c0f4ff54"),
        "b.eq normal fallback only for non-AOD",
    ),
}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    original = args.source.read_bytes()
    actual_sha256 = digest(original)
    if actual_sha256 != SOURCE_SHA256:
        raise SystemExit(
            f"refusing {args.source}: sha256={actual_sha256}, "
            f"expected {SOURCE_SHA256}"
        )

    patched = bytearray(original)
    for offset, (expected, replacement, description) in PATCHES.items():
        actual = original[offset : offset + len(expected)]
        if actual != expected:
            raise SystemExit(
                f"refusing {args.source}: offset {offset:#x} ({description}) "
                f"is {actual.hex()}, expected {expected.hex()}"
            )
        patched[offset : offset + len(replacement)] = replacement

    args.output.write_bytes(patched)
    print(f"source_sha256={actual_sha256}")
    print(f"patched_sha256={digest(bytes(patched))}")
    print("patched_offsets=" + ",".join(f"{offset:#x}" for offset in PATCHES))


if __name__ == "__main__":
    main()
