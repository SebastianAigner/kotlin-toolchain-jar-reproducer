# Checked-in verification evidence

Evidence is grouped by Kotlin Toolchain version. The files are concise outputs
from `reproduce.sh`; full logs remain in the ignored `evidence/latest/`
directory because they include machine-local paths and verbose build output.

| Version | JAR hashes | Changed ZIP timestamps | Extracted payload | Docker layer |
| --- | --- | --- | --- | --- |
| 0.11.1 | different | 130/130 | byte-identical | different |
| 0.12.0 | different | 131/131 | byte-identical | different |

The `0.11.1/` directory is the original verified evidence, moved without
content changes from its former `verified/` name. The `0.12.0/` directory is a
new run made after upgrading both official wrappers. Do not overwrite an older
version's directory when testing a future toolchain; add another versioned
directory so changes in behavior remain visible.
