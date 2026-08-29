# Kotlin Toolchain 0.13.0-dev-4327 executable-JAR behavior

## Summary

Kotlin Toolchain `0.13.0-dev-4327` fixes the production-facing symptom reported
against 0.12.0 through executable-JAR task incrementality. Running
`./kotlin package --format executable-jar` a second time with unchanged inputs
preserves the existing executable JAR and its SHA-256 hash.

Forced clean builds remain nondeterministic. Two `clean` + `package` sequences
from identical inputs produce executable JARs with different hashes. All 131
outer ZIP entry timestamps change. The freshly rebuilt nested application JAR
also differs, but recursively extracting it shows that its four leaf files are
byte-identical and only its four ZIP entry timestamps change. Across both
archives, 135/135 corresponding timestamps differ while entry trees, leaf file
bytes, and non-timestamp ZIP listing metadata match.

The distinction matters: an ordinary unchanged package invocation no longer
invalidates Docker or GraalVM Native Image layers, but a forced clean rebuild
still produces a new digest and invalidates content-addressed consumers.

## Environment

- Kotlin Toolchain: `0.13.0-dev-4327 (c8b4c97, 2026-08-29)`
- Official Unix wrapper SHA-256:
  `8b07cca4f46d86911b1f16d5c1d43f951b062eeba1fad66efb7f3f37a5604bcc`
- Official Windows wrapper SHA-256:
  `1b06daaf84a475315fbd221926e7f0c0c308a1a966a9cea080ed0c6ef0706ab2`
- Project product: `jvm/app`
- Kotlin: `2.4.10`
- JDK: `25`
- Docker client/server: `29.7.2`
- Host kernel: Darwin 25.5.0 (Apple Silicon host, x86_64 process)
- Executable JAR layout: Spring Boot launcher with application classes under
  `BOOT-INF/classes` and dependencies under `BOOT-INF/lib`

The wrappers were updated using JetBrains' official updater:

```console
./kotlin update --target-version=0.13.0-dev-4327
```

The updater pinned the same distribution SHA-256 in both wrappers:
`cdc54918349b8e75e9d938b61885f72af60fdd3fd296c3b4873f27b9e583e00e`.
Both wrapper files retain mode `100755`.

## Verified result

The automated run on 2026-08-29 produced:

```text
bb5d90c7d6c18f6ec0464ef50f1c48527398ff3b1e5307f1201d723a572e7d74  first.jar
bb5d90c7d6c18f6ec0464ef50f1c48527398ff3b1e5307f1201d723a572e7d74  incremental.jar
2bd5045d138c52a7cffe9bb90ae5eb4ff8e7b3546996ac928b2057456166364c  second.jar

ZIP entries with different timestamps: 135/135 across 2 archives
Recursively extracted payloads: byte-identical
Non-timestamp ZIP listing differences: none

first Docker layer:  sha256:e3e6f7e4a68c8ef5ac5b94a153616c852b69aa2d5ac4909727ff25eb1c81b336
second Docker layer: sha256:0b39ae927cbe8e774789f7190433d0efc87729a69ef74ac9c64de4005e6a36ea
```

The unchanged incremental invocation preserved `first.jar`. After the delay
and second clean, the outer archive timestamps moved from `20260829.072650` to
`20260829.072712`; the nested application JAR's timestamps changed in the same
way. The script's payload and non-timestamp metadata diff files were both empty.

## Reproduction

From this repository, run:

```bash
./reproduce.sh
```

The script performs these distinct checks:

1. `clean` and `package` create the first forced-build JAR.
2. A second, ordinary `package` with unchanged inputs must preserve that JAR.
3. A three-second delay crosses ZIP's two-second timestamp resolution.
4. A second `clean` and `package` create the other forced-build JAR from the
   same repository inputs.
5. The clean-build hashes must differ.
6. Corresponding ZIP entry names and non-timestamp listing metadata must match,
   while at least one timestamp must differ.
7. Changed nested ZIP/JAR files are recursively extracted and checked the same
   way; any differing non-archive leaf file fails the run.
8. Docker image and rootfs-layer IDs for the two forced outputs must differ.

The recursive step is necessary in this version: a one-level extraction leaves
`BOOT-INF/lib/kotlin-toolchain-jar-reproducer-jvm.jar` as a differing binary
because that nested archive has its own timestamp-only differences.

The script exits nonzero if incremental packaging rewrites the JAR, clean
rebuilds become identical, archive structure or non-timestamp metadata differs,
an extracted leaf payload differs, timestamps do not differ, or Docker reuses
the JAR layer unexpectedly.

## Expected result

There are two separate expectations:

1. **Incrementality:** an unchanged package task should not rewrite its output.
   `0.13.0-dev-4327` satisfies this expectation.
2. **Reproducibility:** if the task genuinely executes twice from identical
   clean inputs, both artifacts should still be byte-for-byte identical.
   `0.13.0-dev-4327` does not yet satisfy this expectation.

Task incrementality is the direct fix for the motivating production workflow.
Clean-build reproducibility remains valuable for clean CI workers, remote build
caches, artifact stores, provenance checks, registries, and deployment systems.

## Docker and Native Image impact

The motivating production pipeline uses the executable JAR as input to a
native-image builder stage:

```dockerfile
FROM ghcr.io/graalvm/native-image-community:25i2 AS native-builder

COPY application-executable.jar /build/application.jar
RUN jar -xf /build/application.jar
RUN native-image ...
```

Docker keys the `COPY` layer by content. With 0.12.0, an ordinary unchanged
second `package` rewrote the JAR, causing Docker to miss that layer and the
dependent `native-image` layer. In the observed service, native compilation
took roughly 57 seconds and peaked around 3 GiB of memory, while the correctly
cached Docker build took about two seconds. The complete deployment pipeline
was roughly 70 seconds instead of 15 seconds.

In `0.13.0-dev-4327`, the ordinary unchanged second package is incremental and
preserves the JAR, so this production symptom is fixed. The reproducer's two
Docker layers differ only because it deliberately forces both package tasks to
execute by cleaning first.

## Remaining cause and scope

Kotlin Toolchain's ZIP configuration uses reproducible file ordering and does
not preserve source timestamps. The generated archives nevertheless receive
the current build time. The observed clean-build differences are therefore
metadata-only, but they occur at both levels produced by this fixture: the
outer executable JAR and its nested application JAR.

Task incrementality prevents the timestamp-producing assembler from running in
the normal unchanged case. It does not normalize the timestamps when the task
must execute, whether because of `clean`, a fresh checkout, an empty cache, or
a real input change that later returns to identical content.

## Historical 0.12.0 result

The checked-in `evidence/0.12.0/` data records the original behavior. In that
version, a second ordinary package invocation from the same working tree
produced a different executable JAR hash, all 131 outer timestamps changed, and
Docker assigned a different layer. That statement applies to 0.12.0 only and
must not be used to describe `0.13.0-dev-4327`.

The earlier normalization experiment independently extracted two 0.12.0
outputs and repacked them with the JDK `jar` tool using a fixed date,
deterministic ordering, and stored nested dependencies. Both normalized outputs
had this SHA-256 and launched successfully on JDK 25:

```text
fb1a2e0b9585a699fbed9afce73d5ffbedd6b320638c78607f5562d51dbf1b2d
```

## Suggested acceptance tests

Keep two complementary integration tests:

1. Package twice without changing inputs and assert the executable JAR is not
   rewritten and its SHA-256 remains equal.
2. Perform two clean packages of the same fixture, separated by enough time to
   cross ZIP timestamp resolution, and assert archive bytes and metadata remain
   equal.

The first test covers the fixed production symptom. The second exposes the
remaining clean-build reproducibility gap.
