# Kotlin Toolchain 0.13.0-dev-4333 executable-JAR result

## Summary

Kotlin Toolchain `0.13.0-dev-4333` conclusively fixes executable-JAR
reproducibility for this fixture. It retains the incremental behavior added in
the previous dev build and also makes separately executed clean builds
byte-for-byte reproducible.

Two `clean` + `package --format executable-jar` sequences used identical input
manifests and were separated by more than ZIP's two-second timestamp
resolution. Their outer JARs had the same SHA-256. A recursive comparison also
found identical nested archives, leaf payloads, ZIP timestamps, entry trees,
and non-timestamp listing metadata.

Docker was available. Both clean-build JARs produced the same image ID and
rootfs layer diff ID, and Docker marked the second JAR `COPY` step `CACHED`.

## Environment

- Validation date: 2026-08-31
- Kotlin Toolchain: `0.13.0-dev-4333 (3d00bdf, 2026-08-30)`
- Official Unix wrapper SHA-256:
  `08c768b472991e63a5c34f9d47cea506112ec18244e0ed0b0a5cd389b576fbab`
- Official Windows wrapper SHA-256:
  `f03e3047c886f04115cd3c4411487d62cf8efa5043d8251047ad70b011156f9b`
- Pinned distribution SHA-256:
  `27d942308348d07c5d1333c6112684a7fdf53d1491bacdfdaf703e3de713083f`
- Project product: `jvm/app`
- Kotlin: `2.4.10`
- JDK: `25`
- Docker client/server: `29.7.2`
- Host kernel: Darwin 25.6.0 (Apple Silicon host, x86_64 process)
- Validation timezone: Asia/Tokyo

The wrappers were updated using JetBrains' official updater:

```console
./kotlin update --target-version=0.13.0-dev-4333
```

The updater embedded the same distribution checksum in both wrapper files and
retained mode `100755` for each.

## Verified result

The complete run produced one hash for all three observations:

```text
24728a38d51bb3316a84a219cffb66ebb7778e82a4d5db7d61447c69b2773905  first.jar
24728a38d51bb3316a84a219cffb66ebb7778e82a4d5db7d61447c69b2773905  incremental.jar
24728a38d51bb3316a84a219cffb66ebb7778e82a4d5db7d61447c69b2773905  second.jar
```

The unchanged incremental invocation also preserved the built artifact's
modification time at epoch value `1788171793`, confirming that the output file
was not rewritten merely with deterministic bytes.

The forced clean-build comparison found:

```text
Corresponding ZIP/JAR archives:       4
Corresponding ZIP entries:            1233
ZIP entries with changed timestamps:  0
Corresponding non-archive leaf files: 1147
Archive byte differences:             0
Leaf payload differences:             0
Entry-tree differences:               0
Non-timestamp ZIP metadata diffs:     0
Input-manifest differences:           0
```

The four archives were the outer executable JAR and its three nested JARs:
`annotations-13.0.jar`, `kotlin-stdlib-2.4.10.jar`, and
`kotlin-toolchain-jar-reproducer-jvm.jar`.

For the generated outer and application JARs, `zipinfo -T` reported
`19700101.090000` for every sampled entry in both builds. The display reflects
the Asia/Tokyo environment. The dependency archives retained their stable
published timestamps: sampled annotations entries were from 2013, while the
Kotlin standard-library entries used `19800201.000000`. All corresponding
values matched; the three-second delays therefore did cross ZIP resolution
without influencing artifact metadata.

Docker recorded:

```text
first image:  sha256:2c3aa5e2f7ee254bd633c8bc3f431177c7c81f3a5345d511df2d34b023aaa2a5
second image: sha256:2c3aa5e2f7ee254bd633c8bc3f431177c7c81f3a5345d511df2d34b023aaa2a5
rootfs layer: sha256:ef933e9d614bb93e2bbf96ae125c01fdca54131a51b9767cbcce85fa28e46f80
second COPY:  CACHED
```

## Reproduction and comparison method

Run:

```bash
./reproduce.sh
```

The test separates incrementality from clean-build reproducibility:

1. A first `clean` and `package` force creation of an executable JAR.
2. After three seconds, an unchanged ordinary `package` must preserve both the
   JAR SHA-256 and file modification time.
3. After another three seconds, a second `clean` forces the package task to
   execute again. A manifest of the wrappers, module configuration, and source
   inputs must still match the first build's manifest.
4. The two forced-build JAR SHA-256 values must be equal.
5. Every corresponding archive is extracted even when its containing archive
   is already byte-identical. Archive bytes, entry names, ordering-related ZIP
   listing metadata, timestamps, and every leaf file are compared. This makes
   a metadata-only difference distinguishable from a real payload difference.
6. If Docker is available, each clean-build output is copied into a minimal
   `FROM scratch` image. The image ID and rootfs layer list must match.

The empty generated `inputs.diff`, `payload.diff`, and
`non-timestamp-metadata.diff` files provide additional machine-checkable
confirmation during a run.

## Production interpretation

Kotlin Toolchain now produces stable content for both invocation patterns that
matter here. An unchanged package remains incremental, while a forced clean
build no longer receives build-time ZIP metadata. Docker, remote caches,
artifact stores, provenance checks, registries, and other digest-keyed systems
can reuse the resulting artifact when all packaging inputs are identical.

For the motivating pipeline, this prevents an unchanged backend JAR from
invalidating a downstream GraalVM Native Image layer. The observed service's
native compilation took roughly 57 seconds and peaked around 3 GiB of memory,
while a correctly cached Docker build took about two seconds; the full pipeline
was roughly 70 seconds instead of 15 seconds when caching was missed.

## Historical results

### 0.13.0-dev-4327

This version fixed the ordinary unchanged invocation through task
incrementality, but not clean-build reproducibility. Its first and incremental
hashes matched, while the second forced-clean hash differed:

```text
bb5d90c7d6c18f6ec0464ef50f1c48527398ff3b1e5307f1201d723a572e7d74  first.jar
bb5d90c7d6c18f6ec0464ef50f1c48527398ff3b1e5307f1201d723a572e7d74  incremental.jar
2bd5045d138c52a7cffe9bb90ae5eb4ff8e7b3546996ac928b2057456166364c  second.jar
```

All 135 timestamps across the outer and generated application JAR changed,
although recursively extracted leaf payloads matched. Docker consequently
produced different layer diff IDs.

### 0.12.0

This version rewrote the executable JAR even for an ordinary unchanged second
package invocation. All 131 outer timestamps changed and Docker assigned a
different layer. Its checked-in evidence remains available for comparison.

An earlier normalization experiment repacked two 0.12.0 outputs with a fixed
date, deterministic ordering, and stored nested dependencies. Both normalized
outputs had this SHA-256 and launched successfully on JDK 25:

```text
fb1a2e0b9585a699fbed9afce73d5ffbedd6b320638c78607f5562d51dbf1b2d
```

## Suggested acceptance tests

Retain both integration tests:

1. Package twice without changing inputs and assert the output file is not
   rewritten and its SHA-256 remains equal.
2. Perform two clean packages of the same fixture, separated by enough time to
   cross ZIP timestamp resolution, and assert archive bytes, recursively nested
   contents, metadata, and SHA-256 remain equal.
