#!/usr/bin/env python3
"""Pure validation helpers for the release workflow."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


VERSION_PATTERN = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
SHA256_PATTERN = re.compile(r"[0-9a-fA-F]{64}")


class ReleaseIntegrityError(RuntimeError):
    pass


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def expected_assets(version: str, root: Path) -> dict[str, Path]:
    if VERSION_PATTERN.fullmatch(version) is None:
        raise ReleaseIntegrityError(f"Invalid release version: {version!r}")
    return {
        f"DiskInventoryZed-{version}.dmg": root / f"DiskInventoryZed-{version}.dmg",
        "DiskInventoryZed-checksums.txt": root / "DiskInventoryZed-checksums.txt",
        f"DiskInventoryZed-Windows-v{version}-win-x64.zip":
            root / "windows-release" / f"DiskInventoryZed-Windows-v{version}-win-x64.zip",
        f"DiskInventoryZed-Windows-v{version}-win-arm64.zip":
            root / "windows-release" / f"DiskInventoryZed-Windows-v{version}-win-arm64.zip",
        "DiskInventoryZed-Windows-checksums.txt":
            root / "windows-release" / "DiskInventoryZed-Windows-checksums.txt",
    }


def validate_manifest(path: Path, expected_names: set[str]) -> dict[str, str]:
    entries: dict[str, str] = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        fields = line.split()
        if len(fields) != 2 or SHA256_PATTERN.fullmatch(fields[0]) is None:
            raise ReleaseIntegrityError(f"Invalid checksum entry in {path}:{line_number}")
        name = fields[1].removeprefix("*")
        if Path(name).name != name:
            raise ReleaseIntegrityError(f"Checksum paths are not allowed in {path}: {name}")
        if name in entries:
            raise ReleaseIntegrityError(f"Duplicate checksum entry in {path}: {name}")
        entries[name] = fields[0].lower()
    if set(entries) != expected_names:
        raise ReleaseIntegrityError(
            f"Checksum entries differ in {path}: "
            f"expected={sorted(expected_names)}, actual={sorted(entries)}"
        )
    return entries


def _verify_manifest_files(entries: dict[str, str], files: dict[str, Path]) -> None:
    for name, expected_digest in entries.items():
        if digest(files[name]) != expected_digest:
            raise ReleaseIntegrityError(f"Checksum mismatch: {name}")


def verify_local(version: str, root: Path) -> dict[str, Path]:
    assets = expected_assets(version, root)
    for name, path in assets.items():
        if not path.is_file() or path.stat().st_size == 0:
            raise ReleaseIntegrityError(f"Release asset is missing or empty: {name}")
    mac_name = f"DiskInventoryZed-{version}.dmg"
    windows_names = {
        f"DiskInventoryZed-Windows-v{version}-win-x64.zip",
        f"DiskInventoryZed-Windows-v{version}-win-arm64.zip",
    }
    mac_entries = validate_manifest(assets["DiskInventoryZed-checksums.txt"], {mac_name})
    windows_entries = validate_manifest(
        assets["DiskInventoryZed-Windows-checksums.txt"], windows_names
    )
    _verify_manifest_files(mac_entries, assets)
    _verify_manifest_files(windows_entries, assets)
    return assets


def _read_json(path: Path) -> Any:
    with path.open(encoding="utf-8") as source:
        return json.load(source)


def _load_json(path: Path) -> dict[str, Any]:
    document = _read_json(path)
    if not isinstance(document, dict):
        raise ReleaseIntegrityError(f"Expected a JSON object in {path}")
    return document


def _positive_id(value: Any, description: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ReleaseIntegrityError(f"Invalid {description}: {value!r}")
    return value


def _listed_releases(document: Any) -> list[dict[str, Any]]:
    if not isinstance(document, list):
        raise ReleaseIntegrityError("Invalid REST release listing")
    if any(isinstance(item, list) for item in document):
        if not all(isinstance(item, list) for item in document):
            raise ReleaseIntegrityError("Invalid paginated REST release listing")
        raw_releases = [release for page in document for release in page]
    else:
        raw_releases = document

    releases: list[dict[str, Any]] = []
    for release in raw_releases:
        if not isinstance(release, dict) or not isinstance(release.get("tag_name"), str):
            raise ReleaseIntegrityError("The release listing contains an invalid release.")
        _positive_id(release.get("id"), "listed release ID")
        releases.append(release)
    return releases


def require_release_missing(document: Any, tag: str) -> None:
    if any(release["tag_name"] == tag for release in _listed_releases(document)):
        raise ReleaseIntegrityError(
            "Refusing to mutate a preexisting release; remove the stale draft before retrying."
        )


def require_unique_release(document: Any, tag: str, expected_id: int) -> None:
    expected_id = _positive_id(expected_id, "expected release ID")
    matches = [
        release for release in _listed_releases(document)
        if release["tag_name"] == tag
    ]
    if len(matches) != 1 or matches[0]["id"] != expected_id:
        raise ReleaseIntegrityError(
            "The workflow-owned release is not the unique release for this tag."
        )


def release_identity(
    release: dict[str, Any],
    expected_names: set[str],
    tag: str,
    marker: str,
    expected_draft: bool,
    expected_digests: dict[str, str] | None = None,
) -> dict[str, Any]:
    if release.get("tag_name") != tag:
        raise ReleaseIntegrityError("The release tag changed during verification.")
    body = release.get("body")
    if (not isinstance(body, str) or
            (body != marker and not body.startswith(marker + "\n"))):
        raise ReleaseIntegrityError("Release ownership changed during verification.")
    if release.get("draft") is not expected_draft:
        state = "draft" if expected_draft else "published"
        raise ReleaseIntegrityError(f"The release is not in the expected {state} state.")
    if release.get("prerelease") is not False:
        raise ReleaseIntegrityError("The release is marked as a prerelease.")
    if release.get("name") != f"Disk Inventory Zed {tag.removeprefix('v')}":
        raise ReleaseIntegrityError("The release title changed during verification.")
    author = release.get("author")
    if not isinstance(author, dict) or author.get("login") != "github-actions[bot]":
        raise ReleaseIntegrityError("The release author is not the trusted workflow identity.")
    if not expected_draft and release.get("immutable") is not True:
        raise ReleaseIntegrityError("The published release is not immutable.")

    assets: dict[str, list[int | str]] = {}
    raw_assets = release.get("assets")
    if not isinstance(raw_assets, list):
        raise ReleaseIntegrityError("The release asset list is invalid.")
    for asset in raw_assets:
        if not isinstance(asset, dict) or not isinstance(asset.get("name"), str):
            raise ReleaseIntegrityError("The release contains an invalid asset.")
        name = asset["name"]
        if name in assets:
            raise ReleaseIntegrityError(f"The release contains a duplicate asset: {name}")
        asset_id = _positive_id(asset.get("id"), f"asset ID for {name}")
        size = asset.get("size")
        if isinstance(size, bool) or not isinstance(size, int) or size <= 0:
            raise ReleaseIntegrityError(f"Invalid asset size for {name}: {size!r}")
        asset_digest = asset.get("digest")
        if not isinstance(asset_digest, str) or not re.fullmatch(
            r"sha256:[0-9a-f]{64}", asset_digest
        ):
            raise ReleaseIntegrityError(f"Invalid server digest for {name}: {asset_digest!r}")
        if expected_digests is not None:
            expected_digest = expected_digests.get(name)
            if expected_digest is None or asset_digest != f"sha256:{expected_digest}":
                raise ReleaseIntegrityError(
                    f"The server digest does not match this run for {name}."
                )
        if asset.get("state") != "uploaded":
            raise ReleaseIntegrityError(f"Release asset {name} is not fully uploaded.")
        uploader = asset.get("uploader")
        if not isinstance(uploader, dict) or uploader.get("login") != "github-actions[bot]":
            raise ReleaseIntegrityError(f"Release asset {name} has an untrusted uploader.")
        assets[name] = [asset_id, size, asset_digest]
    if set(assets) != expected_names:
        raise ReleaseIntegrityError(
            f"Release asset identities differ: "
            f"expected={sorted(expected_names)}, actual={sorted(assets)}"
        )
    body_digest = hashlib.sha256(body.encode("utf-8")).hexdigest()
    return {
        "id": _positive_id(release.get("id"), "release ID"),
        "bodyDigest": body_digest,
        "assets": assets,
    }


def created_draft_state(
    release: dict[str, Any], version: str, tag: str, marker: str
) -> dict[str, int | str]:
    identity = release_identity(release, set(), tag, marker, True, {})
    if tag != f"v{version}":
        raise ReleaseIntegrityError("The release tag and version do not match.")
    return {
        "id": _positive_id(identity["id"], "created release ID"),
        "bodyDigest": identity["bodyDigest"],
    }


def created_draft_id(
    release: dict[str, Any], version: str, tag: str, marker: str
) -> int:
    return int(created_draft_state(release, version, tag, marker)["id"])


def download_plan(
    release: dict[str, Any],
    version: str,
    root: Path,
    tag: str,
    marker: str,
    expected_id: int,
    created_state: dict[str, Any],
) -> list[tuple[int, str]]:
    local_assets = verify_local(version, root)
    expected_digests = {name: digest(path) for name, path in local_assets.items()}
    identity = release_identity(
        release,
        set(local_assets),
        tag,
        marker,
        True,
        expected_digests,
    )
    if identity["id"] != _positive_id(expected_id, "expected release ID"):
        raise ReleaseIntegrityError("The uploaded draft has an unexpected release ID.")
    if set(created_state) != {"id", "bodyDigest"}:
        raise ReleaseIntegrityError("The created draft state is invalid.")
    created_id = _positive_id(created_state.get("id"), "created release ID")
    body_digest = created_state.get("bodyDigest")
    if (not isinstance(body_digest, str) or
            SHA256_PATTERN.fullmatch(body_digest) is None or
            identity["id"] != created_id or
            identity["bodyDigest"] != body_digest):
        raise ReleaseIntegrityError("The created draft identity changed before download.")
    return sorted(
        (_positive_id(values[0], f"asset ID for {name}"), name)
        for name, values in identity["assets"].items()
    )


def verify_download(
    version: str,
    root: Path,
    download_dir: Path,
    before_json: Path,
    after_json: Path,
    tag: str,
    marker: str,
    state_out: Path,
) -> None:
    local_assets = verify_local(version, root)
    expected_names = set(local_assets)
    downloaded = {path.name: path for path in download_dir.iterdir() if path.is_file()}
    if set(downloaded) != expected_names:
        raise ReleaseIntegrityError(
            f"Downloaded release assets differ: "
            f"expected={sorted(expected_names)}, actual={sorted(downloaded)}"
        )
    for name, local_path in local_assets.items():
        if downloaded[name].stat().st_size == 0:
            raise ReleaseIntegrityError(f"Downloaded release asset is empty: {name}")
        if digest(local_path) != digest(downloaded[name]):
            raise ReleaseIntegrityError(f"Downloaded release asset differs from this run: {name}")

    mac_name = f"DiskInventoryZed-{version}.dmg"
    windows_names = {
        f"DiskInventoryZed-Windows-v{version}-win-x64.zip",
        f"DiskInventoryZed-Windows-v{version}-win-arm64.zip",
    }
    _verify_manifest_files(
        validate_manifest(downloaded["DiskInventoryZed-checksums.txt"], {mac_name}),
        downloaded,
    )
    _verify_manifest_files(
        validate_manifest(downloaded["DiskInventoryZed-Windows-checksums.txt"], windows_names),
        downloaded,
    )

    expected_digests = {name: digest(path) for name, path in local_assets.items()}
    before = release_identity(
        _load_json(before_json), expected_names, tag, marker, True, expected_digests
    )
    after = release_identity(
        _load_json(after_json), expected_names, tag, marker, True, expected_digests
    )
    if before != after:
        raise ReleaseIntegrityError("The release or its assets changed during download verification.")
    state_out.write_text(json.dumps(after, sort_keys=True) + "\n", encoding="utf-8")


def verify_release_state(
    release_json: Path,
    state_path: Path,
    version: str,
    tag: str,
    marker: str,
    expected_draft: bool,
) -> None:
    expected_names = set(expected_assets(version, Path(".")))
    current = release_identity(
        _load_json(release_json), expected_names, tag, marker, expected_draft
    )
    verified = _load_json(state_path)
    if current != verified:
        raise ReleaseIntegrityError("The verified release or asset identities changed.")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    local = commands.add_parser("verify-local")
    local.add_argument("--version", required=True)
    local.add_argument("--root", type=Path, default=Path("."))

    missing = commands.add_parser("require-release-missing")
    missing.add_argument("--json", type=Path, required=True)
    missing.add_argument("--tag", required=True)

    unique = commands.add_parser("require-unique-release")
    unique.add_argument("--json", type=Path, required=True)
    unique.add_argument("--tag", required=True)
    unique.add_argument("--id", type=int, required=True)

    created = commands.add_parser("created-draft-id")
    created.add_argument("--json", type=Path, required=True)
    created.add_argument("--version", required=True)
    created.add_argument("--tag", required=True)
    created.add_argument("--marker", required=True)
    created.add_argument("--state-out", type=Path, required=True)

    plan = commands.add_parser("download-plan")
    plan.add_argument("--json", type=Path, required=True)
    plan.add_argument("--version", required=True)
    plan.add_argument("--root", type=Path, default=Path("."))
    plan.add_argument("--tag", required=True)
    plan.add_argument("--marker", required=True)
    plan.add_argument("--id", type=int, required=True)
    plan.add_argument("--created-state", type=Path, required=True)

    download = commands.add_parser("verify-download")
    download.add_argument("--version", required=True)
    download.add_argument("--root", type=Path, default=Path("."))
    download.add_argument("--download-dir", type=Path, required=True)
    download.add_argument("--before-json", type=Path, required=True)
    download.add_argument("--after-json", type=Path, required=True)
    download.add_argument("--tag", required=True)
    download.add_argument("--marker", required=True)
    download.add_argument("--state-out", type=Path, required=True)

    for name in ("verify-draft", "verify-published"):
        state = commands.add_parser(name)
        state.add_argument("--json", type=Path, required=True)
        state.add_argument("--state", type=Path, required=True)
        state.add_argument("--version", required=True)
        state.add_argument("--tag", required=True)
        state.add_argument("--marker", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "verify-local":
            verify_local(args.version, args.root)
        elif args.command == "require-release-missing":
            require_release_missing(_read_json(args.json), args.tag)
        elif args.command == "require-unique-release":
            require_unique_release(_read_json(args.json), args.tag, args.id)
        elif args.command == "created-draft-id":
            created = created_draft_state(
                _load_json(args.json), args.version, args.tag, args.marker
            )
            args.state_out.write_text(
                json.dumps(created, sort_keys=True) + "\n", encoding="utf-8"
            )
            print(created["id"])
        elif args.command == "download-plan":
            for asset_id, name in download_plan(
                _load_json(args.json),
                args.version,
                args.root,
                args.tag,
                args.marker,
                args.id,
                _load_json(args.created_state),
            ):
                print(f"{asset_id}\t{name}")
        elif args.command == "verify-download":
            verify_download(
                args.version,
                args.root,
                args.download_dir,
                args.before_json,
                args.after_json,
                args.tag,
                args.marker,
                args.state_out,
            )
        else:
            verify_release_state(
                args.json,
                args.state,
                args.version,
                args.tag,
                args.marker,
                args.command == "verify-draft",
            )
    except (OSError, ValueError, ReleaseIntegrityError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
