#!/usr/bin/env bash

set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly EVIDENCE_DIR="$ROOT_DIR/evidence/latest"
readonly WORK_DIR="$EVIDENCE_DIR/work"
readonly FIRST_JAR="$WORK_DIR/first.jar"
readonly INCREMENTAL_JAR="$WORK_DIR/incremental.jar"
readonly SECOND_JAR="$WORK_DIR/second.jar"
readonly DOCKER_JAR="$ROOT_DIR/build/reproducer/app.jar"
readonly FIRST_IMAGE="kotlin-toolchain-jar-reproducer:first"
readonly SECOND_IMAGE="kotlin-toolchain-jar-reproducer:second"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

find_executable_jar() {
    local jars=()
    while IFS= read -r jar; do
        jars+=("$jar")
    done < <(find "$ROOT_DIR/build/tasks" -type f -name '*-executable.jar' -print)
    [[ ${#jars[@]} -eq 1 ]] || fail "expected exactly one executable JAR, found ${#jars[@]}"
    printf '%s\n' "${jars[0]}"
}

timestamp_manifest() {
    zipinfo -T -l "$1" | awk '
        $8 ~ /^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]\.[0-9][0-9][0-9][0-9][0-9][0-9]$/ {
            print $8 "\t" $9
        }
    '
}

non_timestamp_manifest() {
    zipinfo -T -l "$1" | awk '
        $8 ~ /^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]\.[0-9][0-9][0-9][0-9][0-9][0-9]$/ {
            $8 = "<timestamp>"
            print
        }
    '
}

archive_count=0
timestamp_entry_count=0
timestamp_difference_count=0

compare_archive_payloads() {
    local first_archive="$1"
    local second_archive="$2"
    local archive_label="$3"
    local archive_number first_dir second_dir entry_count second_entry_count
    local timestamp_differences relative_path

    archive_count=$((archive_count + 1))
    archive_number="$archive_count"
    first_dir="$WORK_DIR/extracted/$archive_number-first"
    second_dir="$WORK_DIR/extracted/$archive_number-second"
    mkdir -p "$first_dir" "$second_dir"
    unzip -qq "$first_archive" -d "$first_dir"
    unzip -qq "$second_archive" -d "$second_dir"

    (cd "$first_dir" && find . -print | sort) > "$WORK_DIR/tree-$archive_number-first.txt"
    (cd "$second_dir" && find . -print | sort) > "$WORK_DIR/tree-$archive_number-second.txt"
    diff -u "$WORK_DIR/tree-$archive_number-first.txt" "$WORK_DIR/tree-$archive_number-second.txt" \
        >> "$EVIDENCE_DIR/payload.diff" \
        || fail "archive entry trees differ in $archive_label"

    non_timestamp_manifest "$first_archive" > "$WORK_DIR/metadata-$archive_number-first.txt"
    non_timestamp_manifest "$second_archive" > "$WORK_DIR/metadata-$archive_number-second.txt"
    diff -u "$WORK_DIR/metadata-$archive_number-first.txt" \
        "$WORK_DIR/metadata-$archive_number-second.txt" \
        >> "$EVIDENCE_DIR/non-timestamp-metadata.diff" \
        || fail "non-timestamp ZIP metadata differs in $archive_label"

    timestamp_manifest "$first_archive" > "$WORK_DIR/timestamps-$archive_number-first.txt"
    timestamp_manifest "$second_archive" > "$WORK_DIR/timestamps-$archive_number-second.txt"
    entry_count="$(wc -l < "$WORK_DIR/timestamps-$archive_number-first.txt" | tr -d ' ')"
    second_entry_count="$(wc -l < "$WORK_DIR/timestamps-$archive_number-second.txt" | tr -d ' ')"
    [[ "$entry_count" -gt 0 && "$entry_count" -eq "$second_entry_count" ]] \
        || fail "could not compare ZIP timestamp metadata in $archive_label"
    timestamp_differences="$(paste "$WORK_DIR/timestamps-$archive_number-first.txt" \
        "$WORK_DIR/timestamps-$archive_number-second.txt" \
        | awk '$2 != $4 { mismatched = 1 } $1 != $3 { different++ } END {
            if (mismatched) exit 1
            print different + 0
        }')" || fail "ZIP entry names or ordering differ in $archive_label"
    timestamp_entry_count=$((timestamp_entry_count + entry_count))
    timestamp_difference_count=$((timestamp_difference_count + timestamp_differences))
    {
        printf 'archive: %s\n' "$archive_label"
        printf 'entries: %s\n' "$entry_count"
        printf 'entries with different timestamps: %s\n' "$timestamp_differences"
        printf 'first timestamp\tentry\tsecond timestamp\n'
        paste "$WORK_DIR/timestamps-$archive_number-first.txt" \
            "$WORK_DIR/timestamps-$archive_number-second.txt" \
            | awk 'NR <= 10 { print $1 "\t" $2 "\t" $3 }'
        printf '\n'
    } >> "$EVIDENCE_DIR/timestamps.txt"

    while IFS= read -r relative_path; do
        relative_path="${relative_path#./}"
        if ! cmp -s "$first_dir/$relative_path" "$second_dir/$relative_path"; then
            if unzip -tqq "$first_dir/$relative_path" >/dev/null 2>&1 \
                && unzip -tqq "$second_dir/$relative_path" >/dev/null 2>&1; then
                compare_archive_payloads "$first_dir/$relative_path" \
                    "$second_dir/$relative_path" "$archive_label!/$relative_path"
            else
                fail "extracted payload differs at $archive_label!/$relative_path"
            fi
        fi
    done < <(cd "$first_dir" && find . -type f -print | sort)
}

cd "$ROOT_DIR"

for command_name in awk cmp diff docker find sed sort unzip zipinfo; do
    require_command "$command_name"
done
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    fail "required command not found: sha256sum or shasum"
fi
[[ -x "$ROOT_DIR/kotlin" ]] || fail "pinned ./kotlin wrapper is missing or not executable"
docker info >/dev/null 2>&1 || fail "Docker daemon is not available"

rm -rf "$EVIDENCE_DIR"
mkdir -p "$WORK_DIR"

{
    ./kotlin --version
    printf 'Unix wrapper SHA-256: %s\n' "$(sha256 "$ROOT_DIR/kotlin")"
    printf 'Windows wrapper SHA-256: %s\n' "$(sha256 "$ROOT_DIR/kotlin.bat")"
    printf 'Configured compiler: '
    ./kotlin show settings | sed -n 's/^    version: \([^ ]*\)  # module.yaml$/Kotlin \1/p'
    printf 'Configured JDK: JDK '
    ./kotlin show settings | sed -n 's/^      version: \([0-9][0-9]*\)  # .*$/\1/p' | head -n 1
    docker version --format 'Docker client {{.Client.Version}}, server {{.Server.Version}}'
    uname -a
} > "$EVIDENCE_DIR/environment.txt"

printf 'Cleaning and packaging first forced-rebuild executable JAR...\n'
./kotlin clean > "$EVIDENCE_DIR/clean-first.log" 2>&1
mkdir -p "$WORK_DIR"
./kotlin package --format executable-jar > "$EVIDENCE_DIR/package-first.log" 2>&1
artifact_jar="$(find_executable_jar)"
cp "$artifact_jar" "$FIRST_JAR"
mkdir -p "$(dirname "$DOCKER_JAR")"
cp "$FIRST_JAR" "$DOCKER_JAR"

printf 'Building first Docker image...\n'
DOCKER_BUILDKIT=1 docker build --progress=plain --tag "$FIRST_IMAGE" . \
    > "$EVIDENCE_DIR/docker-first.log" 2>&1
docker image inspect --format '{{.Id}} {{json .RootFS.Layers}}' "$FIRST_IMAGE" \
    > "$EVIDENCE_DIR/docker-first.txt"

printf 'Packaging again without changing or cleaning any input...\n'
./kotlin package --format executable-jar > "$EVIDENCE_DIR/package-incremental.log" 2>&1
artifact_jar="$(find_executable_jar)"
cp "$artifact_jar" "$INCREMENTAL_JAR"
incremental_hash="$(sha256 "$INCREMENTAL_JAR")"
first_hash="$(sha256 "$FIRST_JAR")"
[[ "$first_hash" == "$incremental_hash" ]] \
    || fail "unchanged incremental package rewrote the executable JAR"

# ZIP stores timestamps with two-second resolution. Three seconds between the
# two clean rebuilds guarantees different representable timestamp slots.
printf 'Waiting 3 seconds before the second forced clean rebuild...\n'
sleep 3

printf 'Cleaning and packaging second forced-rebuild executable JAR...\n'
./kotlin clean > "$EVIDENCE_DIR/clean-second.log" 2>&1
./kotlin package --format executable-jar > "$EVIDENCE_DIR/package-second.log" 2>&1
artifact_jar="$(find_executable_jar)"
cp "$artifact_jar" "$SECOND_JAR"
mkdir -p "$(dirname "$DOCKER_JAR")"
cp "$SECOND_JAR" "$DOCKER_JAR"

printf 'Building second Docker image...\n'
DOCKER_BUILDKIT=1 docker build --progress=plain --tag "$SECOND_IMAGE" . \
    > "$EVIDENCE_DIR/docker-second.log" 2>&1
docker image inspect --format '{{.Id}} {{json .RootFS.Layers}}' "$SECOND_IMAGE" \
    > "$EVIDENCE_DIR/docker-second.txt"

second_hash="$(sha256 "$SECOND_JAR")"
{
    printf '%s  first.jar\n' "$first_hash"
    printf '%s  incremental.jar\n' "$incremental_hash"
    printf '%s  second.jar\n' "$second_hash"
} > "$EVIDENCE_DIR/hashes.txt"
[[ "$first_hash" != "$second_hash" ]] \
    || fail "forced clean-rebuild JAR hashes are identical; expected timestamp-only nondeterminism"

: > "$EVIDENCE_DIR/payload.diff"
: > "$EVIDENCE_DIR/non-timestamp-metadata.diff"
: > "$EVIDENCE_DIR/timestamps.txt"
compare_archive_payloads "$FIRST_JAR" "$SECOND_JAR" first.jar
[[ "$timestamp_difference_count" -gt 0 ]] \
    || fail "forced clean-rebuild ZIP timestamps are identical"
{
    printf 'PASS: recursively extracted payload files are byte-identical.\n'
    printf 'Compared %s corresponding ZIP archives.\n' "$archive_count"
} > "$EVIDENCE_DIR/payload-comparison.txt"

first_image_id="$(awk '{print $1}' "$EVIDENCE_DIR/docker-first.txt")"
second_image_id="$(awk '{print $1}' "$EVIDENCE_DIR/docker-second.txt")"
first_layers="$(sed 's/^[^ ]* //' "$EVIDENCE_DIR/docker-first.txt")"
second_layers="$(sed 's/^[^ ]* //' "$EVIDENCE_DIR/docker-second.txt")"
[[ "$first_image_id" != "$second_image_id" ]] \
    || fail "Docker image IDs are identical; JAR-dependent image was unexpectedly reused"
[[ "$first_layers" != "$second_layers" ]] \
    || fail "Docker rootfs layer is identical; JAR-dependent COPY layer was unexpectedly reused"
{
    printf 'first image:  %s\n' "$first_image_id"
    printf 'first layers: %s\n' "$first_layers"
    printf 'second image:  %s\n' "$second_image_id"
    printf 'second layers: %s\n' "$second_layers"
    printf 'PASS: the JAR-only rootfs layer changed, proving the COPY layer was invalidated.\n'
} > "$EVIDENCE_DIR/docker-cache.txt"

toolchain_version="$(sed -n 's/^kotlin_cli_version=//p' "$ROOT_DIR/kotlin" | head -n 1)"
printf '\nPASS: Kotlin Toolchain %s executable-JAR behavior demonstrated.\n' "$toolchain_version"
printf '  Unchanged incremental package hash:  %s (preserved)\n' "$incremental_hash"
printf '  Clean-rebuild JAR hashes differ:      %s != %s\n' "$first_hash" "$second_hash"
printf '  Recursively extracted payloads:       byte-identical\n'
printf '  ZIP entries with changed timestamps: %s/%s across %s archives\n' \
    "$timestamp_difference_count" "$timestamp_entry_count" "$archive_count"
printf '  Docker JAR layer:                     invalidated (different diff ID)\n'
printf '  Evidence:                             %s\n' "$EVIDENCE_DIR"
