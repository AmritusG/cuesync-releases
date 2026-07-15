# CSQLite

Vendored SQLite amalgamation, version **3.45.1** (2024-01-30), downloaded from
<https://www.sqlite.org/2024/sqlite-amalgamation-3450100.zip>.

Vendoring the amalgamation (rather than a `systemLibrary` target) means
`CueSyncCore` builds on Windows/Linux/macOS without an "install SQLite"
prerequisite — `sqlite3.c` and `sqlite3.h` are compiled directly into the
`CSQLite` target.

Build flags (set in `Package.swift`): `SQLITE_THREADSAFE=1`,
`SQLITE_OMIT_LOAD_EXTENSION`, `SQLITE_DQS=0`. `EngineDJParser` opens
databases read-only (`SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX`); full
read/write support is still compiled in because the test target creates
fixture databases in-process.

To upgrade: download a newer amalgamation zip from
<https://www.sqlite.org/download.html>, replace `sqlite3.c` and
`include/sqlite3.h`, and update the version above.
