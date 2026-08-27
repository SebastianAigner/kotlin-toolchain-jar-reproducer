#!/usr/bin/env bash

set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly WORK_DIR="$ROOT_DIR/build/reproducer"
readonly EVIDENCE_DIR="$ROOT_DIR/evidence/latest"
readonly FIRST_JAR="$WORK_DIR/first.jar"
readonly SECOND_JAR="$WORK_DIR/second.jar"
readonly DOCKER_JAR="$WORK_DIR/app.jar"
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

cd "$ROOT_DIR"

for command_name in awk diff docker find sed unzip zipinfo; do
    require_command "$command_name"
done
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    fail "required command not found: sha256sum or shasum"
fi
[[ -x "$ROOT_DIR/kotlin" ]] || fail "pinned ./kotlin wrapper is missing or not executable"
docker info >/dev/null 2>&1 || fail "Docker daemon is not available"

rm -rf "$WORK_DIR" "$EVIDENCE_DIR"
mkdir -p "$EVIDENCE_DIR"

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

printf 'Cleaning and packaging first executable JAR...\n'
./kotlin clean > "$EVIDENCE_DIR/clean.log" 2>&1
mkdir -p "$WORK_DIR"
./kotlin package --format executable-jar > "$EVIDENCE_DIR/package-first.log" 2>&1
artifact_jar="$(find_executable_jar)"
cp "$artifact_jar" "$FIRST_JAR"
cp "$FIRST_JAR" "$DOCKER_JAR"

printf 'Building first Docker image...\n'
DOCKER_BUILDKIT=1 docker build --progress=plain --tag "$FIRST_IMAGE" . \
    > "$EVIDENCE_DIR/docker-first.log" 2>&1
docker image inspect --format '{{.Id}} {{json .RootFS.Layers}}' "$FIRST_IMAGE" \
    > "$EVIDENCE_DIR/docker-first.txt"

# ZIP stores timestamps with two-second resolution. Three seconds guarantees
# that the next invocation lands in a different representable time slot.
printf 'Waiting 3 seconds before the unchanged second package invocation...\n'
sleep 3

printf 'Packaging second executable JAR without changing any input...\n'
./kotlin package --format executable-jar > "$EVIDENCE_DIR/package-second.log" 2>&1
artifact_jar="$(find_executable_jar)"
cp "$artifact_jar" "$SECOND_JAR"
cp "$SECOND_JAR" "$DOCKER_JAR"

printf 'Building second Docker image...\n'
DOCKER_BUILDKIT=1 docker build --progress=plain --tag "$SECOND_IMAGE" . \
    > "$EVIDENCE_DIR/docker-second.log" 2>&1
docker image inspect --format '{{.Id}} {{json .RootFS.Layers}}' "$SECOND_IMAGE" \
    > "$EVIDENCE_DIR/docker-second.txt"

first_hash="$(sha256 "$FIRST_JAR")"
second_hash="$(sha256 "$SECOND_JAR")"
{
    printf '%s  first.jar\n' "$first_hash"
    printf '%s  second.jar\n' "$second_hash"
} > "$EVIDENCE_DIR/hashes.txt"
[[ "$first_hash" != "$second_hash" ]] || fail "JAR hashes are identical; issue did not reproduce"

mkdir -p "$WORK_DIR/extracted-first" "$WORK_DIR/extracted-second"
unzip -qq "$FIRST_JAR" -d "$WORK_DIR/extracted-first"
unzip -qq "$SECOND_JAR" -d "$WORK_DIR/extracted-second"
if ! diff -qr "$WORK_DIR/extracted-first" "$WORK_DIR/extracted-second" \
    > "$EVIDENCE_DIR/payload.diff"; then
    fail "extracted JAR payloads differ; this is not a timestamp-only reproduction"
fi
printf 'PASS: all extracted files are byte-identical.\n' > "$EVIDENCE_DIR/payload-comparison.txt"

timestamp_manifest "$FIRST_JAR" > "$WORK_DIR/timestamps-first.txt"
timestamp_manifest "$SECOND_JAR" > "$WORK_DIR/timestamps-second.txt"
entry_count="$(wc -l < "$WORK_DIR/timestamps-first.txt" | tr -d ' ')"
second_entry_count="$(wc -l < "$WORK_DIR/timestamps-second.txt" | tr -d ' ')"
[[ "$entry_count" -gt 0 && "$entry_count" -eq "$second_entry_count" ]] \
    || fail "could not compare ZIP timestamp metadata"
timestamp_differences="$(paste "$WORK_DIR/timestamps-first.txt" "$WORK_DIR/timestamps-second.txt" \
    | awk '$1 != $3 { different++ } END { print different + 0 }')"
[[ "$timestamp_differences" -gt 0 ]] || fail "ZIP timestamps are identical; issue did not reproduce"
{
    printf 'entries: %s\n' "$entry_count"
    printf 'entries with different timestamps: %s\n' "$timestamp_differences"
    printf '\nfirst timestamp\tentry\tsecond timestamp\n'
    paste "$WORK_DIR/timestamps-first.txt" "$WORK_DIR/timestamps-second.txt" \
        | awk 'NR <= 10 { print $1 "\t" $2 "\t" $3 }'
} > "$EVIDENCE_DIR/timestamps.txt"

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
printf '\nPASS: Kotlin Toolchain %s executable-JAR reproducibility issue reproduced.\n' "$toolchain_version"
printf '  JAR hashes differ:                    %s != %s\n' "$first_hash" "$second_hash"
printf '  Extracted payloads:                   byte-identical\n'
printf '  ZIP entries with changed timestamps: %s/%s\n' "$timestamp_differences" "$entry_count"
printf '  Docker JAR layer:                     invalidated (different diff ID)\n'
printf '  Evidence:                             %s\n' "$EVIDENCE_DIR"
