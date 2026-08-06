#!/usr/bin/env python3
"""Materialize an immutable, SHA-256-verified download manifest."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import urllib.request


def fail(message: str) -> None:
    raise SystemExit(message)


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: fetch-verified-files.py manifest.json output-directory")

    manifest_path = Path(sys.argv[1]).resolve(strict=True)
    output_path = Path(sys.argv[2]).resolve(strict=False)
    if output_path.exists():
        fail(f"Output path already exists: {output_path}")
    output_path.parent.mkdir(parents=True, exist_ok=True)

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schemaVersion") != 1 or not isinstance(manifest.get("files"), list):
        fail(f"Unsupported download manifest: {manifest_path}")

    temporary_path = Path(tempfile.mkdtemp(prefix=f".{output_path.name}.", dir=output_path.parent))
    seen_names: set[str] = set()
    try:
        for entry in manifest["files"]:
            name = entry.get("name")
            url = entry.get("url")
            expected_hash = entry.get("sha256")
            if (
                not isinstance(name, str)
                or not name
                or Path(name).name != name
                or name in seen_names
            ):
                fail(f"Unsafe or duplicate download name: {name!r}")
            if not isinstance(url, str) or not url.startswith("https://"):
                fail(f"Download URL must use HTTPS: {url!r}")
            if (
                not isinstance(expected_hash, str)
                or len(expected_hash) != 64
                or any(character not in "0123456789abcdef" for character in expected_hash)
            ):
                fail(f"Invalid SHA-256 for {name}")

            destination = temporary_path / name
            digest = hashlib.sha256()
            request = urllib.request.Request(url, headers={"User-Agent": "DiskInventoryZed-release/1"})
            with urllib.request.urlopen(request, timeout=120) as response, destination.open("xb") as target:
                if not response.geturl().startswith("https://"):
                    fail(f"Download redirected away from HTTPS: {name}")
                while chunk := response.read(1024 * 1024):
                    digest.update(chunk)
                    target.write(chunk)
            actual_hash = digest.hexdigest()
            if actual_hash != expected_hash:
                fail(
                    f"SHA-256 mismatch for {name}: expected {expected_hash}, received {actual_hash}"
                )
            os.chmod(destination, 0o644)
            seen_names.add(name)

        os.replace(temporary_path, output_path)
    except BaseException:
        shutil.rmtree(temporary_path, ignore_errors=True)
        raise

    print(f"Materialized {len(seen_names)} verified files in {output_path}")


if __name__ == "__main__":
    main()
