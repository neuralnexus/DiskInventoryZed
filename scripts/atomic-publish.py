#!/usr/bin/env python3
"""Atomically publish a macOS file or swap a validated directory."""

from __future__ import annotations

import argparse
import ctypes
import os
from pathlib import Path
import stat


AT_FDCWD = -2
RENAME_SWAP = 0x00000002
RENAME_EXCL = 0x00000004


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--replace-directory", action="store_true")
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    return parser.parse_args()


def main() -> None:
    arguments = parse_arguments()
    source = arguments.source.absolute()
    destination = arguments.destination.absolute()
    source_status = source.lstat()
    if stat.S_ISLNK(source_status.st_mode):
        raise SystemExit(f"Publication source must not be a symbolic link: {source}")
    if source.parent.stat().st_dev != destination.parent.stat().st_dev:
        raise SystemExit("Atomic publication requires source and destination on the same filesystem")

    destination_exists = os.path.lexists(destination)
    flags = RENAME_EXCL
    if destination_exists:
        destination_status = destination.lstat()
        if not arguments.replace_directory:
            raise SystemExit(f"Publication destination already exists: {destination}")
        if (
            stat.S_ISLNK(destination_status.st_mode)
            or not stat.S_ISDIR(source_status.st_mode)
            or not stat.S_ISDIR(destination_status.st_mode)
        ):
            raise SystemExit("Directory replacement requires two real directories")
        flags = RENAME_SWAP

    libc = ctypes.CDLL(None, use_errno=True)
    renameatx_np = libc.renameatx_np
    renameatx_np.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    renameatx_np.restype = ctypes.c_int
    result = renameatx_np(
        AT_FDCWD,
        os.fsencode(source),
        AT_FDCWD,
        os.fsencode(destination),
        flags,
    )
    if result != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number), str(destination))


if __name__ == "__main__":
    main()
