# Checked-in verification evidence

The versioned directories contain concise output from verified runs of
`reproduce.sh`. Full logs remain in the ignored `evidence/latest/` directory
because they include machine-local paths and verbose build output.

The rows capture the progression from a non-incremental rewrite, through an
incrementality-only fix, to reproducible forced clean builds. The 0.13.0 dev
evidence compares an unchanged incremental package and two separately forced
clean builds.

| Version | Unchanged incremental hash | Forced clean-build hashes | Changed ZIP timestamps | Recursive payload | Docker layer for forced builds |
| --- | --- | --- | --- | --- | --- |
| 0.12.0 | changed (historical behavior) | not measured | 131/131 outer entries | byte-identical at one extraction level | different |
| 0.13.0-dev-4327 | preserved | different | 135/135 across outer and nested archives | byte-identical leaves | different |
| 0.13.0-dev-4333 | preserved | identical | 0/1233 across 4 archives | 4 identical archives; 1147 identical leaves | reused |
