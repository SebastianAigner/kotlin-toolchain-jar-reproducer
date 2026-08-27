# Kotlin Toolchain executable-JAR reproducibility reproducer

This is a complete, minimal reproducer for a Kotlin Toolchain packaging issue:
two unchanged `package` invocations produce executable JARs with different
SHA-256 hashes. The extracted files are byte-for-byte identical; ZIP entry
timestamps differ.

## Environment

- Kotlin Toolchain 0.11.1 (`801e9d4`, 2026-06-05), pinned by the checked-in
  `kotlin` and `kotlin.bat` wrappers
- Product: `jvm/app`
- Kotlin: 2.4.10, pinned in `module.yaml`
- JDK: 21
- Docker with BuildKit enabled

The application is a single three-line `main` function. It has no third-party
application dependencies. Kotlin Toolchain's `executable-jar` packaging uses a
Spring Boot-style loader layout (`BOOT-INF` and `org/springframework/boot/loader`),
which is the artifact under test.

## Expected behavior

With identical source, configuration, dependencies, toolchain, and environment,
two package invocations should produce byte-identical executable JARs with the
same SHA-256 hash. The second Docker build should then reuse the `COPY` layer
that contains the JAR.

## Actual behavior

Kotlin Toolchain writes the packaging invocation time into the ZIP metadata.
The second executable JAR therefore has a different SHA-256 hash even though
every extracted file is byte-identical. Docker sees different `COPY` input,
creates a different filesystem-layer diff ID, and invalidates that layer and
every downstream layer.

This matters especially for native-image Docker pipelines: an unchanged JAR
can invalidate the layer that feeds an expensive GraalVM compilation, forcing
the native image and all later layers to rebuild. This reproducer intentionally
does **not** run GraalVM. Its `FROM scratch` image contains only the executable
JAR, isolating and proving the cache invalidation cheaply.

## One-command reproduction

Prerequisites are Bash, Docker, `unzip`/`zipinfo`, and standard Unix tools. The
Docker daemon must be running. From this directory, run:

```console
./reproduce.sh
```

The script:

1. cleans and packages an executable JAR;
2. builds a lightweight Docker image containing only that JAR;
3. waits three seconds (greater than ZIP's two-second timestamp resolution);
4. packages again without changing any input and builds the second image;
5. asserts that JAR hashes differ;
6. extracts both JARs and asserts that their payloads are byte-identical;
7. counts corresponding ZIP entries whose timestamps changed; and
8. asserts that the Docker image ID and sole rootfs-layer diff ID changed.

It exits nonzero with a clear `FAIL` message if the issue does not reproduce or
if the observed difference is not timestamp-only. A successful reproduction
ends with `PASS` and writes concise evidence to `evidence/latest/`.

## Captured evidence

The checked-in `evidence/verified/` directory is from a verified run on the
environment above. It contains hashes, a timestamp summary, the extracted
payload comparison, Docker image/layer IDs, and environment details. Raw build
logs from a new run are placed in the ignored `evidence/latest/` directory.

Useful files after a run:

- `evidence/latest/hashes.txt`
- `evidence/latest/payload-comparison.txt`
- `evidence/latest/timestamps.txt`
- `evidence/latest/docker-cache.txt`
- `evidence/latest/docker-first.log` and `docker-second.log`

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
