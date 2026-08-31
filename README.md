# Kotlin Toolchain executable-JAR reproducibility reproducer

This repository confirms that Kotlin Toolchain `0.13.0-dev-4333` fixes
executable-JAR reproducibility, including genuinely executed clean rebuilds:

- An unchanged second `package` invocation preserves the existing executable
  JAR file and its SHA-256 hash.
- Two forced `clean` + `package` rebuilds from identical inputs, separated by
  more than ZIP's two-second timestamp resolution, produce byte-identical JARs.
- All corresponding timestamps, nested archives, archive metadata, and leaf
  payloads match.
- Docker reuses the JAR-dependent `COPY` layer for the two clean-build outputs.

The verified hash for the first clean build, unchanged incremental package,
and second clean build was:

```text
24728a38d51bb3316a84a219cffb66ebb7778e82a4d5db7d61447c69b2773905
```

See [REPORT.md](REPORT.md) for the complete result and historical context.

## Expected and actual behavior

Both expectations now pass:

1. **Incrementality:** packaging with unchanged inputs does not rewrite the
   artifact. After a three-second delay, the executable JAR retained both its
   hash and modification time.
2. **Clean-build reproducibility:** two separately forced clean builds from
   identical inputs produce the same bytes and SHA-256 hash.

The recursive comparison inspected 4 corresponding ZIP/JAR archives, 1,233
ZIP entries, and 1,147 non-archive leaf files. No archive bytes, entry trees,
non-timestamp ZIP listing metadata, timestamps, or leaf payloads differed.

The generated outer executable JAR and nested application JAR use the same
normalized timestamp (`19700101.090000` as displayed by `zipinfo -T` in the
Asia/Tokyo validation environment). Prebuilt dependency JARs retain their own
stable timestamps and are also byte-identical between builds.

## Production interpretation

Content-addressed consumers now see the same artifact after either an
unchanged incremental package or a clean rebuild from the same inputs. In the
validation run, Docker produced the same image ID and rootfs layer diff ID for
both forced-build JARs; the second `COPY` step was explicitly reported as
`CACHED`.

This addresses the motivating Tenchou pipeline problem, where a regenerated
JAR invalidated a downstream GraalVM Native Image layer and increased a full
deployment from roughly 15 seconds to 70 seconds.

## One-command demonstration

Prerequisites are Bash, `unzip`/`zipinfo`, and standard Unix tools. Docker is
used when both its command and daemon are available; otherwise only the Docker
check is skipped. From this directory, run:

```console
./reproduce.sh
```

The script:

1. runs `clean` and packages the first executable JAR;
2. waits three seconds, packages again without changing inputs, and asserts
   that the artifact hash and modification time are preserved;
3. waits another three seconds, runs `clean`, verifies an identical input-file
   manifest, and packages the second executable JAR;
4. asserts equal clean-build SHA-256 hashes;
5. recursively extracts all corresponding nested ZIP/JAR files and compares
   archive bytes, entry trees, timestamps, non-timestamp listing metadata, and
   every non-archive leaf payload; and
6. when Docker is available, asserts equal image and rootfs-layer IDs and
   captures the cached second build.

A successful run writes concise evidence and full logs to the ignored
`evidence/latest/` directory.

## Captured evidence

The checked-in `evidence/0.13.0-dev-4333/` directory contains the confirmed
fixed result. The `0.13.0-dev-4327/` and `0.12.0/` directories remain as
historical evidence of the earlier timestamp nondeterminism. See
[evidence/README.md](evidence/README.md).

## Cleanup

Remove generated files and the two tagged test images with:

```console
./kotlin clean
rm -rf evidence/latest
docker image rm kotlin-toolchain-jar-reproducer:first \
  kotlin-toolchain-jar-reproducer:second
```

Docker may retain untagged cache data; manage that according to the normal
cache policy of the test machine.

## Environment and wrapper pin

- Kotlin Toolchain `0.13.0-dev-4333` (`3d00bdf`, 2026-08-30)
- Official Unix wrapper SHA-256:
  `08c768b472991e63a5c34f9d47cea506112ec18244e0ed0b0a5cd389b576fbab`
- Official Windows wrapper SHA-256:
  `f03e3047c886f04115cd3c4411487d62cf8efa5043d8251047ad70b011156f9b`
- Pinned distribution SHA-256:
  `27d942308348d07c5d1333c6112684a7fdf53d1491bacdfdaf703e3de713083f`
- Product: `jvm/app`
- Kotlin: 2.4.10, pinned in `module.yaml`
- JDK: 25, pinned in `module.yaml`

Both checked-in wrappers were updated with the official command:

```console
./kotlin update --target-version=0.13.0-dev-4333
```

The updater embedded the same distribution checksum in both wrappers and
preserved both executable modes as `100755`.
