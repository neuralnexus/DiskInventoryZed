from __future__ import annotations

import hashlib
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_integrity as integrity  # noqa: E402


class ReleaseIntegrityTests(unittest.TestCase):
    marker = "<!-- disk-inventory-zed-workflow-run:123 -->"
    tag = "v1.2.0"
    version = "1.2.0"

    def test_manifest_accepts_text_and_binary_entries(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "checksums.txt")
            path.write_text(f"{'a' * 64}  one.zip\n{'b' * 64} *two.zip\n", encoding="utf-8")

            entries = integrity.validate_manifest(path, {"one.zip", "two.zip"})

            self.assertEqual({"one.zip", "two.zip"}, set(entries))

    def test_manifest_rejects_duplicates_paths_and_wrong_names(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "checksums.txt")
            cases = (
                f"{'a' * 64}  one.zip\n{'b' * 64}  one.zip\n",
                f"{'a' * 64}  nested/one.zip\n",
                f"{'a' * 64}  two.zip\n",
                "not-a-hash  one.zip\n",
            )
            for content in cases:
                with self.subTest(content=content):
                    path.write_text(content, encoding="utf-8")
                    with self.assertRaises(integrity.ReleaseIntegrityError):
                        integrity.validate_manifest(path, {"one.zip"})

    def test_release_creation_requires_missing_release(self) -> None:
        integrity.require_release_missing([[]], self.tag)

        for change in (
            {},
            {"draft": False},
            {"prerelease": True},
            {"body": "foreign"},
        ):
            with self.subTest(change=change):
                with self.assertRaises(integrity.ReleaseIntegrityError):
                    integrity.require_release_missing(
                        [[self.rest_release({}, draft=True) | change]], self.tag
                    )

        for invalid in ({}, [None], [[{"id": 1, "tag_name": None}]], [[], {}]):
            with self.subTest(invalid=invalid):
                with self.assertRaises(integrity.ReleaseIntegrityError):
                    integrity.require_release_missing(invalid, self.tag)

    def test_created_draft_requires_trusted_empty_release(self) -> None:
        release = self.rest_release({}, draft=True)
        self.assertEqual(
            42,
            integrity.created_draft_id(release, self.version, self.tag, self.marker),
        )
        with self.assertRaises(integrity.ReleaseIntegrityError):
            integrity.created_draft_id(
                release | {"id": 0}, self.version, self.tag, self.marker
            )

        for change in (
            {"body": [self.marker]},
            {"body": "unreviewed replacement\n" + self.marker},
            {"assets": [{"name": "foreign"}]},
            {"author": {"login": "someone-else"}},
        ):
            with self.subTest(change=change):
                with self.assertRaises(integrity.ReleaseIntegrityError):
                    integrity.created_draft_id(
                        release | change, self.version, self.tag, self.marker
                    )

    def test_unique_release_requires_exact_single_id(self) -> None:
        release = self.rest_release({}, draft=True)
        integrity.require_unique_release([[release]], self.tag, 42)
        for listing in (
            [[]],
            [[release, release | {"id": 43}]],
            [[release | {"id": 43}]],
        ):
            with self.subTest(listing=listing):
                with self.assertRaises(integrity.ReleaseIntegrityError):
                    integrity.require_unique_release(listing, self.tag, 42)

    def test_cli_stdout_and_failure_contract(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "release.json")
            path.write_text(
                json.dumps([[self.rest_release({}, draft=True)]]), encoding="utf-8"
            )
            error = io.StringIO()
            with redirect_stderr(error):
                result = integrity.main([
                    "require-release-missing",
                    "--json", str(path),
                    "--tag", self.tag,
                ])
            self.assertEqual(1, result)
            self.assertIn("preexisting release", error.getvalue())

            missing = Path(directory, "missing.json")
            missing.write_text(json.dumps([[]]), encoding="utf-8")
            output = io.StringIO()
            with redirect_stdout(output):
                result = integrity.main([
                    "require-release-missing",
                    "--json", str(missing),
                    "--tag", self.tag,
                ])
            self.assertEqual(0, result)
            self.assertEqual("", output.getvalue())

    def test_download_plan_binds_release_id_assets_and_digests(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            assets = self.write_local_assets(root)
            release = self.rest_release(assets, draft=True)
            created = integrity.created_draft_state(
                self.rest_release({}, draft=True),
                self.version,
                self.tag,
                self.marker,
            )

            plan = integrity.download_plan(
                release, self.version, root, self.tag, self.marker, 42, created
            )

            self.assertEqual(sorted(assets), sorted(name for _, name in plan))
            with self.assertRaises(integrity.ReleaseIntegrityError):
                integrity.download_plan(
                    release, self.version, root, self.tag, self.marker, 43, created
                )
            with self.assertRaises(integrity.ReleaseIntegrityError):
                integrity.download_plan(
                    release | {"body": self.marker + "\nchanged"},
                    self.version,
                    root,
                    self.tag,
                    self.marker,
                    42,
                    created,
                )

    def test_verify_download_binds_bytes_and_release_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            assets = self.write_local_assets(root)
            download = root / "download"
            download.mkdir()
            for name, path in assets.items():
                (download / name).write_bytes(path.read_bytes())
            before = root / "before.json"
            after = root / "after.json"
            release = self.rest_release(assets, draft=True)
            before.write_text(json.dumps(release), encoding="utf-8")
            after.write_text(json.dumps(release), encoding="utf-8")
            state = root / "state.json"

            integrity.verify_download(
                self.version,
                root,
                download,
                before,
                after,
                self.tag,
                self.marker,
                state,
            )
            integrity.verify_release_state(
                after, state, self.version, self.tag, self.marker, True
            )

            published = root / "published.json"
            published.write_text(json.dumps(self.rest_release(assets, draft=False)), encoding="utf-8")
            integrity.verify_release_state(
                published, state, self.version, self.tag, self.marker, False
            )

    def test_verify_download_rejects_byte_and_identity_changes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            assets = self.write_local_assets(root)
            download = root / "download"
            download.mkdir()
            for name, path in assets.items():
                (download / name).write_bytes(path.read_bytes())
            before = root / "before.json"
            after = root / "after.json"
            before.write_text(json.dumps(self.rest_release(assets, draft=True)), encoding="utf-8")
            changed = self.rest_release(assets, draft=True)
            changed["assets"][0]["id"] += 1
            after.write_text(json.dumps(changed), encoding="utf-8")

            with self.assertRaises(integrity.ReleaseIntegrityError):
                integrity.verify_download(
                    self.version,
                    root,
                    download,
                    before,
                    after,
                    self.tag,
                    self.marker,
                    root / "state.json",
                )

            after.write_text(before.read_text(encoding="utf-8"), encoding="utf-8")
            next(iter(download.iterdir())).write_bytes(b"changed")
            with self.assertRaises(integrity.ReleaseIntegrityError):
                integrity.verify_download(
                    self.version,
                    root,
                    download,
                    before,
                    after,
                    self.tag,
                    self.marker,
                    root / "state.json",
                )

    def test_release_identity_rejects_prerelease_and_duplicate_assets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            assets = self.write_local_assets(Path(directory))
            release = self.rest_release(assets, draft=True)
            release["prerelease"] = True
            with self.assertRaises(integrity.ReleaseIntegrityError):
                integrity.release_identity(release, set(assets), self.tag, self.marker, True)

    def test_release_identity_requires_trusted_metadata_and_immutable_publication(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            assets = self.write_local_assets(Path(directory))
            for change in (
                {"name": "Unexpected title"},
                {"author": {"login": "someone-else"}},
                {"immutable": False},
            ):
                with self.subTest(change=change):
                    release = self.rest_release(assets, draft=False)
                    release.update(change)
                    with self.assertRaises(integrity.ReleaseIntegrityError):
                        integrity.release_identity(
                            release, set(assets), self.tag, self.marker, False
                        )

            for asset_change in (
                {"digest": "sha256:" + "0" * 64},
                {"state": "new"},
                {"uploader": {"login": "someone-else"}},
            ):
                with self.subTest(asset_change=asset_change):
                    release = self.rest_release(assets, draft=True)
                    release["assets"][0].update(asset_change)
                    expected = {name: self.sha(path) for name, path in assets.items()}
                    with self.assertRaises(integrity.ReleaseIntegrityError):
                        integrity.release_identity(
                            release,
                            set(assets),
                            self.tag,
                            self.marker,
                            True,
                            expected,
                        )

            release = self.rest_release(assets, draft=True)
            release["assets"].append(dict(release["assets"][0]))
            with self.assertRaises(integrity.ReleaseIntegrityError):
                integrity.release_identity(release, set(assets), self.tag, self.marker, True)

    def write_local_assets(self, root: Path) -> dict[str, Path]:
        windows = root / "windows-release"
        windows.mkdir()
        dmg_name = f"DiskInventoryZed-{self.version}.dmg"
        x64_name = f"DiskInventoryZed-Windows-v{self.version}-win-x64.zip"
        arm_name = f"DiskInventoryZed-Windows-v{self.version}-win-arm64.zip"
        (root / dmg_name).write_bytes(b"dmg")
        (windows / x64_name).write_bytes(b"x64")
        (windows / arm_name).write_bytes(b"arm64")
        (root / "DiskInventoryZed-checksums.txt").write_text(
            f"{self.sha(root / dmg_name)}  {dmg_name}\n", encoding="utf-8"
        )
        (windows / "DiskInventoryZed-Windows-checksums.txt").write_text(
            f"{self.sha(windows / x64_name)}  {x64_name}\n"
            f"{self.sha(windows / arm_name)}  {arm_name}\n",
            encoding="utf-8",
        )
        return integrity.expected_assets(self.version, root)

    def rest_release(self, assets: dict[str, Path], draft: bool) -> dict[str, object]:
        return {
            "id": 42,
            "tag_name": self.tag,
            "name": f"Disk Inventory Zed {self.version}",
            "body": self.marker,
            "draft": draft,
            "prerelease": False,
            "immutable": not draft,
            "author": {"login": "github-actions[bot]"},
            "assets": [
                {
                    "id": index + 100,
                    "name": name,
                    "size": path.stat().st_size,
                    "digest": f"sha256:{self.sha(path)}",
                    "state": "uploaded",
                    "uploader": {"login": "github-actions[bot]"},
                }
                for index, (name, path) in enumerate(assets.items())
            ],
        }

    @staticmethod
    def sha(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()


if __name__ == "__main__":
    unittest.main()
