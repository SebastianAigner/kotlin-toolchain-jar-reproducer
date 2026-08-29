# Kotlin Toolchain executable-JAR clean-rebuild reproducer

This repository documents the behavior of Kotlin Toolchain
`0.13.0-dev-4327` for executable JAR packaging:

- An unchanged second `package` invocation is incremental and preserves the
  existing executable JAR byte-for-byte.
- **Two forced clean rebuilds from identical inputs regenerate the executable JAR
  with different ZIP timestamps and SHA-256 hashes.**
- **Recursively extracting the outer executable JAR and its changed nested
  application JAR produces byte-identical leaf payloads. Their non-timestamp
  ZIP listing metadata also matches.**
- **A Docker `COPY` layer changes when it consumes the two forced-rebuild JARs.**

This is an important improvement over 0.12.0. The dev build fixes the observed
production symptom through executable-JAR task incrementality: an ordinary
unchanged second `package` no longer rewrites the JAR and therefore does not
invalidate content-addressed consumers. The underlying clean-build output is
still not reproducible.

See [REPORT.md](REPORT.md) for the full result, production interpretation, and
historical context.

## Expected and actual behavior

The incremental behavior now matches expectations: when no packaging input has
changed, Kotlin Toolchain reuses the existing executable JAR and its SHA-256
hash remains stable.

Ideally, genuinely executed clean builds from identical source, configuration,
dependencies, toolchain, and environment would also produce byte-identical
artifacts. In `0.13.0-dev-4327`, each clean rebuild writes its execution time to
the ZIP entries. The outer archive also contains the freshly rebuilt
application JAR, whose own entries have the same timestamp-only behavior.

Consequently, clean-rebuild JAR hashes differ even though recursively extracted
leaf files are byte-identical. Docker sees different `COPY` input and creates a
different filesystem-layer diff ID.

## Production interpretation

For the motivating Tenchou pipeline, avoiding an unnecessary JAR rewrite also
avoids invalidating a downstream GraalVM Native Image layer. That was the
production problem: the complete deployment took roughly 70 seconds instead
of 15 seconds, or about five times longer, when an unchanged backend artifact
was regenerated.

With `0.13.0-dev-4327`, an ordinary unchanged incremental `package` preserves
the JAR, so that specific production symptom is fixed. A deliberately forced
clean rebuild still changes the artifact digest and therefore invalidates a
Docker layer or any other digest-keyed consumer. This reproducer uses a tiny
`FROM scratch` image to demonstrate that remaining behavior without running
GraalVM Native Image.

## One-command demonstration

Prerequisites are Bash, Docker, `unzip`/`zipinfo`, and standard Unix tools. The
Docker daemon must be running. The script supports the same macOS/Linux
environments as before. From this directory, run:

```console
./reproduce.sh
```

The script:

1. runs `clean`, packages the first executable JAR, and builds a Docker image;
2. packages again without changing inputs or cleaning, and asserts that the
   JAR hash is unchanged;
3. waits three seconds, exceeding ZIP's two-second timestamp resolution;
4. runs `clean` again, packages the second executable JAR, and builds another
   Docker image;
5. asserts that the two clean-rebuild JAR hashes differ;
6. recursively extracts changed nested ZIP/JAR entries and asserts that all
   leaf payload files are byte-identical;
7. asserts that corresponding archive entry trees and non-timestamp ZIP
   listing metadata match, while explicitly counting changed timestamps; and
8. asserts that the forced-rebuild Docker image and rootfs-layer IDs differ.

It exits nonzero if the incremental invocation rewrites the JAR, if the clean
rebuilds unexpectedly become byte-for-byte identical, or if any observed
difference cannot be accounted for by ZIP timestamps. A successful run writes
concise evidence and full logs to the ignored `evidence/latest/` directory.

## Captured evidence

The checked-in `evidence/0.13.0-dev-4327/` directory contains concise output
from the current validation. `evidence/0.12.0/` is retained as historical
evidence for the old non-incremental behavior. See
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

- Kotlin Toolchain `0.13.0-dev-4327` (`c8b4c97`, 2026-08-29)
- Official Unix wrapper SHA-256:
  `8b07cca4f46d86911b1f16d5c1d43f951b062eeba1fad66efb7f3f37a5604bcc`
- Official Windows wrapper SHA-256:
  `1b06daaf84a475315fbd221926e7f0c0c308a1a966a9cea080ed0c6ef0706ab2`
- Product: `jvm/app`
- Kotlin: 2.4.10, pinned in `module.yaml`
- JDK: 25, pinned in `module.yaml`

Both checked-in wrappers were updated with the official command:

```console
./kotlin update --target-version=0.13.0-dev-4327
```

The updater supplied the distribution checksum embedded in both wrappers and
preserved their executable file modes. The application remains a single
three-line `main` function with no third-party application dependencies.
