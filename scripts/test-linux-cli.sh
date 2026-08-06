#!/bin/bash
set -euo pipefail

readonly BINARY_PATH="${1:?usage: test-linux-cli.sh path/to/DiskInventoryZed [expected-version]}"
readonly EXPECTED_VERSION="${2:-1.2}"

if [ ! -x "$BINARY_PATH" ]; then
    echo "CLI binary is not executable: $BINARY_PATH" >&2
    exit 1
fi

WORK_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/DiskInventoryZed-cli-test.XXXXXX")"
readonly WORK_DIRECTORY
readonly STANDARD_OUTPUT="$WORK_DIRECTORY/stdout"
readonly STANDARD_ERROR="$WORK_DIRECTORY/stderr"

cleanup() {
    rm -rf "$WORK_DIRECTORY"
}
trap cleanup EXIT

run_with_status() {
    set +e
    "$@" >"$STANDARD_OUTPUT" 2>"$STANDARD_ERROR"
    RUN_STATUS=$?
    set -e
}

expect_status() {
    local expected="$1"
    shift
    run_with_status "$@"
    if [ "$RUN_STATUS" -ne "$expected" ]; then
        echo "Expected status $expected, received $RUN_STATUS: $*" >&2
        return 1
    fi
}

expect_status 0 "$BINARY_PATH" --help
grep -q '^Usage: DiskInventoryZed' "$STANDARD_OUTPUT"
test ! -s "$STANDARD_ERROR"

expect_status 0 "$BINARY_PATH" --version
test "$(tr -d '\r\n' < "$STANDARD_OUTPUT")" = "DiskInventoryZed $EXPECTED_VERSION"
test ! -s "$STANDARD_ERROR"

expect_status 2 "$BINARY_PATH"
grep -q 'A directory path is required' "$STANDARD_ERROR"
expect_status 2 "$BINARY_PATH" ""
grep -q 'A directory path is required' "$STANDARD_ERROR"
expect_status 2 "$BINARY_PATH" --json "" /tmp
grep -q -- '--json requires an output path' "$STANDARD_ERROR"
expect_status 2 "$BINARY_PATH" --unknown /tmp
grep -q 'Unknown option' "$STANDARD_ERROR"

readonly SOURCE_DIRECTORY="$WORK_DIRECTORY/source"
readonly DEFAULT_OUTPUT="$WORK_DIRECTORY/default.json"
readonly FILTERED_OUTPUT="$WORK_DIRECTORY/filtered.json"
mkdir -p "$SOURCE_DIRECTORY/nested"
printf 'visible\n' > "$SOURCE_DIRECTORY/nested/visible.txt"
printf 'hidden\n' > "$SOURCE_DIRECTORY/.hidden.txt"

expect_status 0 "$BINARY_PATH" --json "$DEFAULT_OUTPUT" "$SOURCE_DIRECTORY"
test ! -s "$STANDARD_ERROR"
test "$(stat -c '%a' "$DEFAULT_OUTPUT")" = 600
python3 - "$DEFAULT_OUTPUT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    document = json.load(source)
names = {entry["name"] for entry in document["entries"]}
assert "visible.txt" in names
assert ".hidden.txt" in names
assert document["options"]["showHiddenFiles"] is True
PY

expect_status 0 "$BINARY_PATH" --exclude-hidden --json "$FILTERED_OUTPUT" "$SOURCE_DIRECTORY"
test ! -s "$STANDARD_ERROR"
python3 - "$FILTERED_OUTPUT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    document = json.load(source)
names = {entry["name"] for entry in document["entries"]}
assert "visible.txt" in names
assert ".hidden.txt" not in names
assert document["options"]["showHiddenFiles"] is False
PY

readonly EXISTING_OUTPUT="$WORK_DIRECTORY/existing.json"
printf 'unchanged\n' > "$EXISTING_OUTPUT"
expect_status 1 "$BINARY_PATH" --json "$EXISTING_OUTPUT" "$SOURCE_DIRECTORY"
test "$(tr -d '\r\n' < "$EXISTING_OUTPUT")" = unchanged

readonly MISSING_PATH="$WORK_DIRECTORY/does-not-exist"
expect_status 1 "$BINARY_PATH" "$MISSING_PATH"
grep -Fq "$MISSING_PATH" "$STANDARD_ERROR"

expect_status 2 "$BINARY_PATH" $'--unsafe\u2028record' /tmp
python3 - "$STANDARD_ERROR" <<'PY'
from pathlib import Path
import sys

output = Path(sys.argv[1]).read_text(encoding="utf-8")
assert "\\u{2028}" in output or "\\u2028" in output
assert "\u2028" not in output
PY

echo "Linux CLI acceptance checks passed"
