#!/bin/bash
set -euo pipefail
umask 077

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${TAG_NAME:?TAG_NAME is required}"
if [ "$#" -eq 0 ]; then
    echo "usage: publish-release.sh release-asset [...]" >&2
    exit 2
fi

readonly RELEASE_MARKER="<!-- DiskInventoryZed release workflow commit: ${GITHUB_SHA} -->"
TEMPORARY_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/DiskInventoryZed-release.XXXXXX")"
readonly TEMPORARY_DIRECTORY
readonly EXPECTED_ASSETS="$TEMPORARY_DIRECTORY/expected-assets.json"
readonly RELEASES_PATH="$TEMPORARY_DIRECTORY/releases.json"
readonly SELECTED_RELEASE_PATH="$TEMPORARY_DIRECTORY/selected-release.json"
readonly CREATED_RELEASE_PATH="$TEMPORARY_DIRECTORY/created-release.json"
readonly REMOTE_ASSETS_PATH="$TEMPORARY_DIRECTORY/remote-assets.json"
readonly REQUEST_PATH="$TEMPORARY_DIRECTORY/request.json"

cleanup() {
    rm -rf "$TEMPORARY_DIRECTORY"
}
trap cleanup EXIT

python3 - "$EXPECTED_ASSETS" "$@" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

output = Path(sys.argv[1])
assets = []
names = set()
for value in sys.argv[2:]:
    path = Path(value)
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"Release asset is missing or unsafe: {path}")
    if path.name in names:
        raise SystemExit(f"Duplicate release asset name: {path.name}")
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    assets.append({
        "name": path.name,
        "path": str(path),
        "size": path.stat().st_size,
        "digest": f"sha256:{digest.hexdigest()}",
    })
    names.add(path.name)
output.write_text(json.dumps(assets, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

verify_release_refs() {
    local remote_tag_commit
    local remote_main_commit
    git fetch --no-tags origin "refs/tags/${TAG_NAME}"
    remote_tag_commit="$(git rev-parse --verify 'FETCH_HEAD^{commit}')"
    if [ "$remote_tag_commit" != "$GITHUB_SHA" ]; then
        echo "Remote tag $TAG_NAME no longer resolves to $GITHUB_SHA." >&2
        return 1
    fi
    git fetch --no-tags origin main
    remote_main_commit="$(git rev-parse --verify 'origin/main^{commit}')"
    if [ "$remote_main_commit" != "$GITHUB_SHA" ]; then
        echo "The release commit is no longer the current origin/main commit." >&2
        return 1
    fi
}

verify_published_release() {
    local release_id="$1"
    gh api "repos/${GITHUB_REPOSITORY}/releases/${release_id}" >"$SELECTED_RELEASE_PATH"
    python3 - \
        "$SELECTED_RELEASE_PATH" \
        "$TAG_NAME" \
        "$GITHUB_SHA" \
        "$EXPECTED_ASSETS" <<'PY'
import json
from pathlib import Path
import sys

release = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = {
    asset["name"]: asset
    for asset in json.loads(Path(sys.argv[4]).read_text(encoding="utf-8"))
}
remote = {asset["name"]: asset for asset in release.get("assets", [])}
if release.get("tag_name") != sys.argv[2]:
    raise SystemExit("Published release tag does not match")
if release.get("target_commitish") != sys.argv[3]:
    raise SystemExit("Published release target does not match")
if release.get("draft") or release.get("prerelease") or not release.get("published_at"):
    raise SystemExit("Release did not reach the expected published state")
if release.get("immutable") is not True:
    raise SystemExit("Published release is not immutable")
if set(remote) != set(expected):
    raise SystemExit("Published release asset set does not match")
for name, local in expected.items():
    asset = remote[name]
    if asset.get("state") != "uploaded":
        raise SystemExit(f"Published asset is incomplete: {name}")
    if asset.get("size") != local["size"] or asset.get("digest") != local["digest"]:
        raise SystemExit(f"Published asset does not match: {name}")
PY
}

verify_release_refs

gh api --paginate --slurp \
    "repos/${GITHUB_REPOSITORY}/releases?per_page=100" >"$RELEASES_PATH"
RELEASE_STATE="$(python3 - \
    "$RELEASES_PATH" \
    "$SELECTED_RELEASE_PATH" \
    "$TAG_NAME" <<'PY'
import json
from pathlib import Path
import sys

pages = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
releases = [release for page in pages for release in page]
matches = [release for release in releases if release["tag_name"] == sys.argv[3]]
if len(matches) > 1:
    raise SystemExit(f"Multiple releases exist for tag {sys.argv[3]}")
if not matches:
    print("missing")
else:
    Path(sys.argv[2]).write_text(
        json.dumps(matches[0], indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print("draft" if matches[0]["draft"] else "published")
PY
)"
readonly RELEASE_STATE

verify_remote_assets() {
    local release_id="$1"
    gh api --paginate --slurp \
        "repos/${GITHUB_REPOSITORY}/releases/${release_id}/assets?per_page=100" \
        >"$REMOTE_ASSETS_PATH"
    python3 - "$EXPECTED_ASSETS" "$REMOTE_ASSETS_PATH" <<'PY'
import json
from pathlib import Path
import sys

expected = {
    asset["name"]: asset
    for asset in json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
}
pages = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
remote_list = [asset for page in pages for asset in page]
remote = {asset["name"]: asset for asset in remote_list}
if len(remote) != len(remote_list):
    raise SystemExit("The release contains duplicate asset names")
if set(remote) != set(expected):
    raise SystemExit(
        f"Release asset set mismatch: expected {sorted(expected)}, received {sorted(remote)}"
    )
for name, local in expected.items():
    asset = remote[name]
    if asset.get("state") != "uploaded":
        raise SystemExit(f"Release asset is not fully uploaded: {name}")
    if asset.get("size") != local["size"]:
        raise SystemExit(f"Release asset size mismatch: {name}")
    if asset.get("digest") != local["digest"]:
        raise SystemExit(f"Release asset digest mismatch: {name}")
PY
}

if [ "$RELEASE_STATE" = published ]; then
    PUBLISHED_RELEASE_ID="$(python3 -c \
        'import json,sys; print(json.load(open(sys.argv[1]))["id"])' \
        "$SELECTED_RELEASE_PATH")"
    readonly PUBLISHED_RELEASE_ID
    verify_remote_assets "$PUBLISHED_RELEASE_ID"
    verify_published_release "$PUBLISHED_RELEASE_ID"
    echo "Published release $TAG_NAME already contains the exact expected assets."
    exit 0
fi

if [ "$RELEASE_STATE" = draft ]; then
    python3 - \
        "$SELECTED_RELEASE_PATH" \
        "$RELEASE_MARKER" \
        "$GITHUB_SHA" <<'PY'
import json
from pathlib import Path
import sys

release = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if sys.argv[2] not in (release.get("body") or ""):
    raise SystemExit("An unrecognized draft already exists for this tag")
if release.get("target_commitish") != sys.argv[3]:
    raise SystemExit("The workflow-owned draft targets a different commit")
PY
    STALE_RELEASE_ID="$(python3 -c \
        'import json,sys; print(json.load(open(sys.argv[1]))["id"])' \
        "$SELECTED_RELEASE_PATH")"
    readonly STALE_RELEASE_ID
    gh api --method DELETE \
        "repos/${GITHUB_REPOSITORY}/releases/${STALE_RELEASE_ID}"
fi

python3 - \
    "$REQUEST_PATH" \
    "$TAG_NAME" \
    "$GITHUB_SHA" \
    "$RELEASE_MARKER" <<'PY'
import json
from pathlib import Path
import sys

Path(sys.argv[1]).write_text(json.dumps({
    "tag_name": sys.argv[2],
    "target_commitish": sys.argv[3],
    "name": sys.argv[2],
    "body": sys.argv[4],
    "draft": True,
    "generate_release_notes": True,
}, sort_keys=True), encoding="utf-8")
PY
gh api --method POST \
    "repos/${GITHUB_REPOSITORY}/releases" \
    --input "$REQUEST_PATH" >"$CREATED_RELEASE_PATH"
RELEASE_ID="$(python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["id"])' \
    "$CREATED_RELEASE_PATH")"
readonly RELEASE_ID
UPLOAD_URL="$(python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["upload_url"].split("{")[0])' \
    "$CREATED_RELEASE_PATH")"
readonly UPLOAD_URL

while IFS= read -r asset_path; do
    asset_name="$(basename "$asset_path")"
    encoded_name="$(python3 -c \
        'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' \
        "$asset_name")"
    gh api --method POST \
        -H "Content-Type: application/octet-stream" \
        --input "$asset_path" \
        "${UPLOAD_URL}?name=${encoded_name}" >/dev/null
done < <(python3 -c \
    'import json,sys; [print(asset["path"]) for asset in json.load(open(sys.argv[1]))]' \
    "$EXPECTED_ASSETS")

verified=false
for attempt in 1 2 3 4 5; do
    if verify_remote_assets "$RELEASE_ID"; then
        verified=true
        break
    fi
    sleep "$attempt"
done
if [ "$verified" != true ]; then
    echo "Uploaded release assets did not pass final digest verification." >&2
    exit 1
fi

RELEASE_DRAFT="$(gh api "repos/${GITHUB_REPOSITORY}/releases/${RELEASE_ID}" --jq .draft)"
if [ "$RELEASE_DRAFT" != true ]; then
    echo "Release $TAG_NAME was published before the workflow's final gate." >&2
    exit 1
fi
verify_release_refs
verify_remote_assets "$RELEASE_ID"
RELEASE_DRAFT="$(gh api "repos/${GITHUB_REPOSITORY}/releases/${RELEASE_ID}" --jq .draft)"
if [ "$RELEASE_DRAFT" != true ]; then
    echo "Release $TAG_NAME changed state before publication." >&2
    exit 1
fi
python3 - "$REQUEST_PATH" <<'PY'
import json
from pathlib import Path
import sys

Path(sys.argv[1]).write_text(json.dumps({"draft": False}), encoding="utf-8")
PY
gh api --method PATCH \
    "repos/${GITHUB_REPOSITORY}/releases/${RELEASE_ID}" \
    --input "$REQUEST_PATH" >/dev/null

published=false
for attempt in 1 2 3 4 5 6; do
    if verify_published_release "$RELEASE_ID"; then
        published=true
        break
    fi
    sleep "$attempt"
done
if [ "$published" != true ]; then
    echo "Release $TAG_NAME did not become immutable and complete." >&2
    exit 1
fi
verify_release_refs
python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["html_url"])' \
    "$SELECTED_RELEASE_PATH"
