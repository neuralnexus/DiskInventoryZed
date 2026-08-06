#!/usr/bin/env python3
"""Generate a deterministic SPDX 2.3 SBOM for a portable Linux release."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path


def file_hash(path: Path, algorithm: str) -> str:
    digest = hashlib.new(algorithm)
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--archive-name")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--architecture", choices=("x86_64", "aarch64"), required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--source-archive", required=True)
    parser.add_argument("--source-sha256", required=True)
    parser.add_argument("--source-date-epoch", type=int, required=True)
    parser.add_argument("--components", type=Path, required=True)
    parser.add_argument("--licenses", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    arguments = parse_arguments()
    manifest = json.loads(arguments.components.read_text(encoding="utf-8"))
    if manifest.get("schemaVersion") != 1:
        raise SystemExit("Unsupported third-party component manifest")

    expected_license_hashes = {
        entry["name"]: entry["sha256"] for entry in manifest["files"]
    }
    for name, expected_hash in expected_license_hashes.items():
        path = arguments.licenses / name
        if file_hash(path, "sha256") != expected_hash:
            raise SystemExit(f"License payload hash mismatch: {name}")

    binary_sha256 = file_hash(arguments.binary, "sha256")
    binary_sha1 = file_hash(arguments.binary, "sha1")
    archive_sha256 = file_hash(arguments.archive, "sha256")
    archive_name = arguments.archive_name or arguments.archive.name
    release_base = (
        f"https://github.com/neuralnexus/DiskInventoryZed/releases/download/v{arguments.version}"
    )
    archive_id = "SPDXRef-Package-ReleaseArchive"
    application_id = "SPDXRef-Package-DiskInventoryZed"
    binary_id = "SPDXRef-File-DiskInventoryZed"
    created = datetime.fromtimestamp(
        arguments.source_date_epoch, timezone.utc
    ).strftime("%Y-%m-%dT%H:%M:%SZ")

    archive_package = {
        "SPDXID": archive_id,
        "name": f"DiskInventoryZed Linux {arguments.architecture} release archive",
        "versionInfo": arguments.version,
        "packageFileName": archive_name,
        "downloadLocation": f"{release_base}/{archive_name}",
        "filesAnalyzed": False,
        "checksums": [{"algorithm": "SHA256", "checksumValue": archive_sha256}],
        "homepage": "https://github.com/neuralnexus/DiskInventoryZed",
        "licenseConcluded": "GPL-3.0-or-later",
        "licenseDeclared": "GPL-3.0-or-later",
        "copyrightText": "NOASSERTION",
        "primaryPackagePurpose": "ARCHIVE",
        "sourceInfo": (
            f"Project commit {arguments.commit}; corresponding source "
            f"{arguments.source_archive} (SHA-256 {arguments.source_sha256})"
        ),
        "externalRefs": [{
            "referenceCategory": "OTHER",
            "referenceType": "corresponding-source",
            "referenceLocator": (
                f"{release_base}/{arguments.source_archive}#sha256="
                f"{arguments.source_sha256}"
            ),
        }],
    }

    application_package = {
        "SPDXID": application_id,
        "name": "DiskInventoryZed",
        "versionInfo": arguments.version,
        "packageFileName": "DiskInventoryZed",
        "downloadLocation": f"{release_base}/{archive_name}",
        "filesAnalyzed": True,
        "packageVerificationCode": {
            "packageVerificationCodeValue": hashlib.sha1(
                binary_sha1.encode("ascii")
            ).hexdigest()
        },
        "checksums": [{"algorithm": "SHA256", "checksumValue": binary_sha256}],
        "homepage": "https://github.com/neuralnexus/DiskInventoryZed",
        "licenseConcluded": "GPL-3.0-or-later",
        "licenseDeclared": "GPL-3.0-or-later",
        "licenseInfoFromFiles": ["GPL-3.0-or-later"],
        "copyrightText": "Copyright (C) 2026 Matt Ivan",
        "primaryPackagePurpose": "APPLICATION",
        "sourceInfo": (
            f"Project commit {arguments.commit}; corresponding source "
            f"{arguments.source_archive} (SHA-256 {arguments.source_sha256})"
        ),
        "externalRefs": [
            {
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": (
                    "pkg:github/neuralnexus/DiskInventoryZed@"
                    f"{arguments.commit}?arch={arguments.architecture}"
                ),
            },
        ],
    }

    dependency_packages = []
    relationships = [
        {
            "spdxElementId": "SPDXRef-DOCUMENT",
            "relationshipType": "DESCRIBES",
            "relatedSpdxElement": archive_id,
        },
        {
            "spdxElementId": archive_id,
            "relationshipType": "CONTAINS",
            "relatedSpdxElement": application_id,
        },
        {
            "spdxElementId": application_id,
            "relationshipType": "CONTAINS",
            "relatedSpdxElement": binary_id,
        },
    ]
    for component in manifest["components"]:
        dependency_packages.append({
            "SPDXID": component["SPDXID"],
            "name": component["name"],
            "versionInfo": component["versionInfo"],
            "downloadLocation": component["downloadLocation"],
            "filesAnalyzed": False,
            "licenseConcluded": component["licenseConcluded"],
            "licenseDeclared": component["licenseConcluded"],
            "copyrightText": "NOASSERTION",
            "primaryPackagePurpose": "LIBRARY",
            "sourceInfo": component.get(
                "sourceInfo",
                f"Revision: {component['revision']}",
            ),
            "externalRefs": [{
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": component["purl"],
            }],
        })
        relationships.append({
            "spdxElementId": application_id,
            "relationshipType": "STATIC_LINK",
            "relatedSpdxElement": component["SPDXID"],
        })

    extracted_licenses = []
    for license_id, name in (
        ("LicenseRef-ICU-76104.3-ThirdParty", "ICU-76104.3-LICENSE.txt"),
        ("LicenseRef-musl-1.2.5", "musl-COPYRIGHT.txt"),
    ):
        extracted_licenses.append({
            "licenseId": license_id,
            "name": name,
            "extractedText": (arguments.licenses / name).read_text(encoding="utf-8"),
        })

    document = {
        "SPDXID": "SPDXRef-DOCUMENT",
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "name": f"DiskInventoryZed-{arguments.version}-linux-{arguments.architecture}",
        "documentNamespace": (
            "https://github.com/neuralnexus/DiskInventoryZed/spdx/"
            f"{arguments.version}/linux/{arguments.architecture}/{archive_sha256}"
        ),
        "creationInfo": {
            "created": created,
            "creators": ["Tool: DiskInventoryZed-generate-linux-sbom/1"],
            "licenseListVersion": "3.27",
        },
        "documentDescribes": [archive_id],
        "packages": [archive_package, application_package, *dependency_packages],
        "files": [{
            "SPDXID": binary_id,
            "fileName": "./DiskInventoryZed",
            "checksums": [
                {"algorithm": "SHA1", "checksumValue": binary_sha1},
                {"algorithm": "SHA256", "checksumValue": binary_sha256},
            ],
            "licenseConcluded": "GPL-3.0-or-later",
            "licenseInfoInFiles": ["GPL-3.0-or-later"],
            "copyrightText": "Copyright (C) 2026 Matt Ivan",
            "fileTypes": ["BINARY", "APPLICATION"],
        }],
        "relationships": relationships,
        "hasExtractedLicensingInfos": extracted_licenses,
    }
    arguments.output.write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
