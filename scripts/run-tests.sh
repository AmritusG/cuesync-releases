#!/usr/bin/env bash
#
# Standalone unit/fuzz test runner for CueSync's parser / exporter / model layer.
#
# The app's parsers, exporters and models depend only on Foundation (+ SQLite3 and
# Compression for Engine DJ), so they can be compiled and exercised without the
# SwiftUI app. This script:
#   1. generates SQLite + binary fixtures,
#   2. compiles Tests/main.swift + Tests/CueSyncTests.swift against those sources,
#   3. runs EACH test in its own process so a trap/crash in one test is reported
#      as CRASH instead of taking down the whole suite (main.swift has a 20s
#      per-process watchdog for infinite loops).
#
# Exit code: 0 = all green, 1 = failures/crashes, 2 = compile/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$SCRIPT_DIR/../CueSync"                 # cue-sync-build/CueSync (xcodeproj + Tests + source)
cd "$PROJ" || { echo "cannot cd to $PROJ"; exit 2; }

FIX="${CUESYNC_FIXTURES:-/tmp/cuesync-test-fixtures}"
# NB: not "cuesync-tests" — main.swift creates a temp *directory* of that name.
BIN="${TMPDIR:-/tmp}/cuesync-tests.bin"

echo "==> Generating fixtures in $FIX"
rm -rf "$FIX"; mkdir -p "$FIX"

TRACK_DDL="CREATE TABLE Track(id INTEGER PRIMARY KEY, title TEXT, artist TEXT, album TEXT, genre TEXT, length INTEGER, bpmAnalyzed REAL, key INTEGER, path TEXT, filename TEXT);"

sqlite3 "$FIX/engine-good.db" <<SQL
$TRACK_DDL
INSERT INTO Track VALUES(1,'Test Title','Test Artist','Album','Genre',180,128.0,1,'/Music/','track.mp3');
INSERT INTO Track VALUES(2,'','','','',0,0.0,0,'','fallback.wav');
CREATE TABLE PerformanceData(trackId INTEGER, quickCues BLOB);
SQL

sqlite3 "$FIX/engine-no-perf.db" <<SQL
$TRACK_DDL
INSERT INTO Track VALUES(1,'X','','','',60,120.0,1,'/m/','a.mp3');
SQL

sqlite3 "$FIX/engine-empty.db" <<SQL
$TRACK_DDL
CREATE TABLE PerformanceData(trackId INTEGER, quickCues BLOB);
SQL

# quickCues blob: first 4 bytes = LE uint32 uncompressed size (100), rest = garbage
# that cannot zlib-decompress -> parser must return the track with no cues, not crash.
sqlite3 "$FIX/engine-badblob.db" <<SQL
$TRACK_DDL
INSERT INTO Track VALUES(1,'Blobby','','','',90,120.0,1,'/m/','b.mp3');
CREATE TABLE PerformanceData(trackId INTEGER, quickCues BLOB);
INSERT INTO PerformanceData VALUES(1, X'64000000DEADBEEFDEADBEEFCAFEBABE');
SQL

# A non-SQLite file: open succeeds lazily, first query must fail -> parse() throws.
head -c 64 /dev/urandom > "$FIX/engine-corrupt.db"

echo "==> Compiling test binary"
SRC=( CueSync/Models/*.swift CueSync/Parsers/*.swift CueSync/Exporters/*.swift )
if ! swiftc -O -o "$BIN" Tests/main.swift Tests/CueSyncTests.swift "${SRC[@]}" -lsqlite3; then
  echo "COMPILE FAILED"; exit 2
fi

echo "==> Running tests (each in its own process)"
export CUESYNC_FIXTURES="$FIX"
names=$("$BIN" list) || { echo "could not list tests"; exit 2; }

pass=0; fail=0; crash=0
failed_names=()
for n in $names; do
  out=$("$BIN" "$n" 2>&1); code=$?
  case $code in
    0)   echo "  ok    $n"; pass=$((pass+1));;
    1)   echo "  FAIL  $n"; echo "$out" | sed 's/^/        /'; fail=$((fail+1)); failed_names+=("$n");;
    124) echo "  TIMEOUT $n (>20s, possible infinite loop)"; fail=$((fail+1)); failed_names+=("$n");;
    *)   echo "  CRASH $n (exit $code)"; echo "$out" | sed 's/^/        /'; crash=$((crash+1)); failed_names+=("$n");;
  esac
done

echo
echo "==> Summary: $pass passed, $fail failed, $crash crashed (of $((pass+fail+crash)))"
if [ ${#failed_names[@]} -gt 0 ]; then
  echo "    not green: ${failed_names[*]}"
  exit 1
fi
echo "ALL GREEN"
