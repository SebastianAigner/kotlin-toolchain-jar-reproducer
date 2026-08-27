# Kotlin Toolchain executable JARs remain non-reproducible across unchanged package runs

## Summary

Running `./kotlin package` twice without changing any project input produces
executable JARs with different SHA-256 hashes. The original finding was made
with Kotlin Toolchain 0.11.1 and was reverified with the latest official release,
0.12.0, on 2026-08-27.

In each comparison, the two archives have the same size and entry count, and
their extracted payloads are byte-identical. Their ZIP metadata differs because
every entry receives the wall-clock time of the package invocation. This
defeats content-addressed build caches. In particular, a Docker `COPY` of the
executable JAR is invalidated on every package invocation, which also
invalidates an expensive downstream GraalVM Native Image layer.

## Current verification: Kotlin Toolchain 0.12.0

The repository's automated test packages the minimal application twice, waits
long enough to cross ZIP's two-second timestamp resolution, compares the JARs
and their extracted payloads, and builds a `FROM scratch` Docker image from each
JAR. The 0.12.0 run produced:

```text
1ce1500e00e8cf6820d56916ce70a9abc70e2e1ea2840c2e820c074978c99086  first.jar
468c661dfcf90f53913c3bd6e6997c84ddea73886f60f35f2fdcffe55b0a129e  second.jar

ZIP entries with different timestamps: 131/131
Extracted payloads: byte-identical

first Docker layer:  sha256:bfec786ec6d6a353dacc33b8e2ffa81be1eca542c922a2d5f582e8fa5d156174
second Docker layer: sha256:47f94c364abdfaf64fffac255006d25143419a3f2cb2f6a06ae48739b5d1b7bf
```

This is the same failure mode as 0.11.1: only archive metadata changes, but the
JAR digest and Docker layer identity change. The issue is therefore not fixed
in 0.12.0.

### Current environment

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

The wrappers were obtained with JetBrains' official `./kotlin update` command
from the JetBrains Kotlin Toolchain Maven repository and verified byte-for-byte
against the published 0.12.0 wrapper artifacts.

## Historical 0.11.1 finding

The following environment and measurements document the original finding. They
are retained as historical evidence and have not been rewritten to look like a
0.12.0 run.

### Original environment

- Kotlin Toolchain: `0.11.1 (801e9d4, 2026-06-05)`
- Project product: `jvm/app`
- Kotlin: `2.4.10`
- JVM target: `21`
- Java used for verification: Amazon Corretto `21.0.12`
- Host: Darwin 25.5.0, `x86_64`
- Executable JAR layout: Spring Boot launcher with application classes under
  `BOOT-INF/classes` and dependencies under `BOOT-INF/lib`

The relevant project configuration is:

```yaml
product: jvm/app

settings:
  kotlin:
    version: 2.4.10
  jvm:
    jdk:
      version: 21
    mainClass: io.sebi.tenchou.ApplicationKt
```

## Standalone reproducer

A separate minimal repository, `kotlin-toolchain-jar-reproducer`, contains a
single-function `jvm/app`, pinned Kotlin Toolchain wrappers, and a one-command
automated test:

```bash
./reproduce.sh
```

The script packages twice without changing an input, compares the archives and
their extracted trees, and builds a `FROM scratch` Docker image whose only
filesystem layer is the executable JAR. It exits nonzero unless it observes the
specific timestamp-only reproducibility failure and the resulting Docker layer
invalidation.

The original verified 0.11.1 minimal run produced:

```text
2873ed2a98b4550801e72a7778cda85ab03d980163464d712d93b1ca1dee5b7f  first.jar
468765ffbd725bacb13201e963e615e8bb4114e210483df40ba06fdc731b15fa  second.jar

ZIP entries with different timestamps: 130/130
Extracted payloads: byte-identical

first Docker layer:  sha256:c6f64934ab3a513ea8086ed0d6438347c5da1639b474110c7a848548936f8af9
second Docker layer: sha256:003bc47db80e1db9682196e25aee85d3efef9d7f790c6125e7378b26e0502f68
```

The complete script, README, and concise captured evidence are committed in
that repository as commit `d73eb50`.

## Minimal reproduction procedure

Starting from an unchanged, already compilable Kotlin Toolchain `jvm/app`
project:

```bash
repro_dir="$(mktemp -d)"
executable_jar="build/tasks/_tenchou_executableJarJvm/tenchou-jvm-executable.jar"

./kotlin package
cp "$executable_jar" "$repro_dir/first.jar"

sleep 4

./kotlin package
cp "$executable_jar" "$repro_dir/second.jar"

shasum -a 256 "$repro_dir/first.jar" "$repro_dir/second.jar"

mkdir "$repro_dir/first" "$repro_dir/second"
unzip -qq "$repro_dir/first.jar" -d "$repro_dir/first"
unzip -qq "$repro_dir/second.jar" -d "$repro_dir/second"
diff -qr "$repro_dir/first" "$repro_dir/second"

diff -u \
  <(zipinfo -v "$repro_dir/first.jar") \
  <(zipinfo -v "$repro_dir/second.jar")
```

The `sleep` only ensures that the second run crosses the two-second resolution
of a DOS ZIP timestamp. No project file is modified between the two package
invocations.

## Original application observation

In the motivating application investigation with 0.11.1, the two directly
produced archives differed:

```text
a4c3ae6a5ed1bbe90e7e4766fb2cada303ec45ff52a9bc0f2642f6eff1ece1b8  first.jar
182dbcbda73eaec6315b79326a4617017388786e7833ffae291ddfa03de32ec9  second.jar
```

Both archives were exactly 22,227,580 bytes and contained 225 entries.
`diff -qr` over the two extracted directory trees produced no output: every
extracted file was byte-identical.

`zipinfo -v` showed the metadata difference repeated for every entry:

```diff
- file last modified on (DOS date/time): 2026 Aug 27 16:15:36
+ file last modified on (DOS date/time): 2026 Aug 27 16:15:40
```

The first differing bytes reported by `cmp -l` were the DOS timestamp bytes in
successive local file headers. CRCs, compressed sizes, uncompressed sizes, and
extracted contents were unchanged.

## Expected result

Two `package` executions with identical inputs should produce byte-for-byte
identical executable JARs:

```text
sha256(first.jar) == sha256(second.jar)
```

Ideally, the packaging task could also be skipped as up to date when none of its
inputs changed. However, even when the task executes, its output should be
reproducible.

## Docker and Native Image impact

The production pipeline uses the executable JAR as the input of a native-image
builder stage:

```dockerfile
FROM ghcr.io/graalvm/native-image-community:25i2 AS native-builder

COPY build/tasks/_tenchou_executableJarJvm/tenchou-jvm-executable.jar /build/tenchou.jar

RUN jar -xf /build/tenchou.jar
RUN native-image ...
```

Docker keys the `COPY` layer by file content. Because the executable JAR hash
changes on every `package` invocation, Docker cannot reuse either the `COPY`
layer or the dependent `native-image` layer—even when all class files,
resources, dependency JARs, and configuration are identical.

In the observed application, JVM packaging takes only a few seconds while the
downstream native compilation takes roughly 48 seconds and peaks around 2.76
GiB of memory. The timestamp-only difference therefore turns a no-op package
run into a complete native rebuild. It would similarly cause misses in remote
build caches, artifact stores, provenance checks, and any deployment system
that uses the JAR digest as an identity.

## Root-cause hypothesis

The executable-JAR assembly appears to assign the current packaging time to
every output entry. The evidence does not indicate a changed compiler or
resource payload; after extraction, the output trees are identical.

A reproducible archive would normally use a stable entry order and normalized
timestamps, while preserving any ZIP storage requirements of nested executable
JAR layouts.

## Practical workarounds

Until Kotlin Toolchain produces reproducible executable JARs, we have used two
application-level mitigations:

1. **Skip packaging when backend inputs are unchanged.** Compute a content
   fingerprint over the Kotlin sources, resources, module configuration, and
   pinned toolchain wrapper. If it matches the fingerprint recorded for the
   existing executable JAR, reuse that exact JAR instead of invoking
   `./kotlin package`. This preserves its digest and therefore the downstream
   Docker and native-image cache. The input list must be maintained carefully,
   and clean builds or toolchain changes must force a new package run.
2. **Keep frequently changed static files outside the executable.** For the
   motivating service, the Vite frontend is copied into a separate runtime
   image layer and served from a filesystem directory selected by an
   environment variable. A frontend-only change then rebuilds only that small
   layer; it does not require executable-JAR packaging or GraalVM compilation.

In a timed production verification of those two mitigations, an insignificant
frontend change took 36 seconds from starting the source edit to independently
observing the exact new artifact at the production URL. The deployment script
accounted for 15 seconds of that interval, and Docker reported the executable
JAR copy, extraction, and GraalVM native-image steps as cached.

Archive normalization is another possible workaround: rebuild the ZIP with a
fixed timestamp and deterministic ordering. Nested executable-JAR dependencies
must remain stored rather than compressed, and launchability should be tested
after rewriting. The experiment below demonstrates that this works for the
observed layout, but an upstream Kotlin Toolchain fix is preferable because it
can preserve all format invariants centrally.

## Independent normalization experiment

As a diagnostic—not a proposed user-facing workaround—the two extracted trees
were repacked using the JDK `jar` tool with a fixed timestamp and stored entries:

```bash
jar --create \
  --no-manifest \
  --no-compress \
  --date=2020-01-01T00:00:00Z \
  --file normalized.jar \
  -C extracted .
```

Both independently normalized outputs had the same SHA-256:

```text
3f2e0c24a8976b119a64d3223ab3ef6ef54a6baa30ec38dbef833eadda49edd8
```

The normalized executable JAR also launched successfully and passed the
application health check. This confirms that normalizing archive metadata is
sufficient to restore reproducibility for the observed inputs. The use of
`--no-compress` in this diagnostic preserves the storage requirements of nested
Spring Boot dependency JARs; it is not intended as the preferred Kotlin
Toolchain implementation.

## Suggested acceptance test

A Kotlin Toolchain integration test could package the same small `jvm/app`
fixture twice in distinct clean output directories, then assert:

1. the executable JAR SHA-256 values are equal;
2. the archive entry order is equal;
3. every corresponding entry has equal content and metadata; and
4. a content-addressed consumer such as a Docker `COPY` layer remains cached on
   the second build.
