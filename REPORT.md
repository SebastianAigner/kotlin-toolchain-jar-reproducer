# Kotlin Toolchain 0.12.0 executable JARs are not reproducible

## Summary

With Kotlin Toolchain 0.12.0, running `./kotlin package` twice without changing
any project input produces executable JARs with different SHA-256 hashes.

The two archives have the same size and entry count, and their extracted
payloads are byte-identical. All 131 ZIP entry timestamps change to the
wall-clock time of the packaging invocation. This defeats content-addressed
build caches: a Docker `COPY` of the JAR is invalidated, along with an
expensive downstream GraalVM Native Image layer.

Version 0.12.0 was the latest official Kotlin Toolchain release when verified on
2026-08-27.

## Environment

- Kotlin Toolchain: `0.12.0 (2039c53, 2026-08-25)`
- Official Unix wrapper SHA-256:
  `b9a4ebe4e5f846057609203f82a19730414d69ca692178d094e2a6f99f5526c7`
- Official Windows wrapper SHA-256:
  `a54dc5cdd48dc0753dabaa2eeabefa45860f1fc6b5024da6b0f07a9990ece837`
- Project product: `jvm/app`
- Kotlin: `2.4.10`
- JDK: `25`
- Docker client/server: `29.7.2`
- Host kernel: Darwin 25.5.0 (Apple Silicon host, x86_64 process)
- Executable JAR layout: Spring Boot launcher with application classes under
  `BOOT-INF/classes` and dependencies under `BOOT-INF/lib`

The wrappers were obtained with JetBrains' official `./kotlin update` command
and verified byte-for-byte against the published 0.12.0 wrapper artifacts.

## Verified result

The automated run produced:

```text
1ce1500e00e8cf6820d56916ce70a9abc70e2e1ea2840c2e820c074978c99086  first.jar
468c661dfcf90f53913c3bd6e6997c84ddea73886f60f35f2fdcffe55b0a129e  second.jar

ZIP entries with different timestamps: 131/131
Extracted payloads: byte-identical

first Docker layer:  sha256:bfec786ec6d6a353dacc33b8e2ffa81be1eca542c922a2d5f582e8fa5d156174
second Docker layer: sha256:47f94c364abdfaf64fffac255006d25143419a3f2cb2f6a06ae48739b5d1b7bf
```

The first differing bytes are the DOS timestamp fields in successive local ZIP
headers. Corresponding extracted files are identical.

## Reproduction

From this repository, run:

```bash
./reproduce.sh
```

The script:

1. cleans and packages the minimal `jvm/app`;
2. builds a `FROM scratch` Docker image whose only layer is that JAR;
3. waits long enough to cross ZIP's two-second timestamp resolution;
4. packages again without changing any input;
5. compares JAR hashes, extracted payloads, and ZIP timestamps; and
6. verifies that Docker assigns a different root filesystem layer.

It exits nonzero unless it observes the timestamp-only JAR difference and
resulting Docker cache invalidation.

The timestamp evidence includes entries such as:

```diff
- 20260827.171234  META-INF/MANIFEST.MF
+ 20260827.171240  META-INF/MANIFEST.MF
```

## Expected result

Two `package` executions with identical inputs should produce byte-for-byte
identical executable JARs:

```text
sha256(first.jar) == sha256(second.jar)
```

Ideally, packaging could also be skipped when none of its inputs changed.
However, even when the task executes, its output should be reproducible.

## Docker and Native Image impact

The motivating production pipeline uses the executable JAR as the input of a
native-image builder stage:

```dockerfile
FROM ghcr.io/graalvm/native-image-community:25i2 AS native-builder

COPY application-executable.jar /build/application.jar
RUN jar -xf /build/application.jar
RUN native-image ...
```

Docker keys the `COPY` layer by file content. Because the JAR digest changes
on every `package` invocation, Docker cannot reuse that layer or the dependent
`native-image` layer, even though all classes, resources, dependency JARs, and
configuration are identical.

In the observed service, native compilation took roughly 57 seconds and peaked
around 3 GiB of memory, while the correctly cached Docker build took about two
seconds. In the complete deployment pipeline, that was roughly 70 seconds
instead of 15 seconds, or about five times slower.

The same timestamp-only difference can also cause misses in remote build caches,
artifact stores, provenance checks, registries, and deployment systems that use
the JAR digest as an identity.

## Root cause

Kotlin Toolchain's current ZIP configuration declares:

- `reproducibleFileOrder = true`
- `preserveFileTimestamps = false`

However, when timestamp preservation is disabled, the implementation creates a
new `ZipEntry` without assigning it a normalized timestamp. Java's
`ZipOutputStream.putNextEntry` assigns the current time when an entry has no
modification time. Thus, `preserveFileTimestamps=false` currently means “do not
copy the source timestamp,” rather than “write a stable timestamp.”

The executable-JAR assembler uses this ZIP configuration directly. Stable
ordering is therefore enabled, but timestamps remain nondeterministic.

## Public issue search

A search of the public Kotlin Toolchain/Amper YouTrack history, GitHub issues,
pull requests, commits, and source history found no exact ticket tracking this
timestamp/hash reproducibility defect.

Related tickets cover creation of executable JARs, Spring Boot loader behavior,
or Docker/OCI output generally, but not changing ZIP timestamps or invalidated
content-addressed caches. The strongest classification is an untracked
implementation bug in the existing reproducibility logic.

## Practical workarounds

Until Kotlin Toolchain produces reproducible executable JARs:

1. **Skip packaging when backend inputs are unchanged.** Compute a content
   fingerprint over sources, resources, module configuration, and the pinned
   wrapper. If it matches the existing executable JAR, reuse that exact JAR.
2. **Keep frequently changed static files outside the executable.** Copy a web
   frontend into a separate runtime image layer and serve it from the
   filesystem. Frontend-only changes then avoid JAR packaging and native
   compilation.
3. **Normalize the archive after packaging.** Repack with a fixed timestamp and
   deterministic ordering. Nested executable-JAR dependencies must remain
   stored rather than compressed.

A timed production verification of the first two mitigations took 36 seconds
from beginning a frontend edit to observing it in production. The deployment
script itself took 15 seconds, with the JAR and native-image layers cached.

## Normalization experiment

The two Kotlin Toolchain 0.12.0 outputs were independently extracted and
repacked using the JDK `jar` tool:

```bash
jar --create \
  --no-manifest \
  --no-compress \
  --date=2020-01-01T00:00:00Z \
  --file normalized.jar \
  -C extracted .
```

Both normalized outputs had the same SHA-256:

```text
fb1a2e0b9585a699fbed9afce73d5ffbedd6b320638c78607f5562d51dbf1b2d
```

The normalized executable JAR launched successfully on JDK 25. This confirms
that normalizing archive metadata is sufficient for the observed layout.
`--no-compress` preserves the storage requirement of nested Spring Boot
dependency JARs; an upstream fix should preserve this invariant centrally.

## Suggested acceptance test

A Kotlin Toolchain integration test could package the same small `jvm/app`
fixture twice, then assert:

1. the executable JAR SHA-256 values are equal;
2. archive entry order and metadata are equal;
3. corresponding entry contents are equal; and
4. a content-addressed consumer such as a Docker `COPY` layer remains cached.
