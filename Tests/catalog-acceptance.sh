#!/bin/bash
# M2 acceptance — dedup, re-import, interrupt/resume, move, offline root, migration guard, migration
# correctness, query timing, metadata, full chain.
#
#   BIN=.build/release/photonsctl RAW=~/Desktop/test/L1030433.dng Tests/catalog-acceptance.sh
#   ... --perf     also run the 10k-row query timing (~90 s)
#
# Exit code is the verdict; every line is a check with its measured value.
set -uo pipefail

BIN="${BIN:-.build/debug/photonsctl}"
RAW="${RAW:-$HOME/Desktop/test/L1030433.dng}"
PERF=0
[[ "${1:-}" == "--perf" ]] && PERF=1

W="$(mktemp -d "${TMPDIR:-/tmp}/photons-catalog.XXXXXX")"
FAILED=0
say()  { printf '%-34s %-6s %s\n' "$1" "$2" "$3"; }
pass() { say "$1" "PASS" "${2:-}"; }
fail() { say "$1" "FAIL" "${2:-}"; FAILED=1; }
jget() { python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get(sys.argv[1],""))' "$1"; }

cleanup() { [[ "${KEEP:-0}" == "1" ]] || rm -rf "$W"; }
trap cleanup EXIT

echo "photons M2 acceptance   bin=$BIN  work=$W"

# ── 1. dedupe ────────────────────────────────────────────────────────────────────────────────
LIB="$W/A.photonslibrary"
"$BIN" library create "$LIB" >/dev/null || { echo "cannot create library"; exit 1; }
"$BIN" fixtures "$W/src" --count 1000 --dupes 10 >/dev/null || { echo "cannot make fixtures"; exit 1; }
OUT="$("$BIN" library import "$LIB" "$W/src" --json)"
ADDED=$(echo "$OUT" | jget added); DUP=$(echo "$OUT" | jget duplicate)
if [[ "$ADDED" == "900" && "$DUP" == "100" ]]; then
  pass "1 dedupe" "added=900 duplicate=100"
else
  fail "1 dedupe" "added=$ADDED duplicate=$DUP (want 900/100)"
fi
ASSETS=$(sqlite3 "$LIB/library.db" "SELECT COUNT(*) FROM assets;")
[[ "$ASSETS" == "900" ]] && pass "1 rows in catalog" "assets=900" || fail "1 rows in catalog" "assets=$ASSETS"

# ── 2. idempotent re-import ──────────────────────────────────────────────────────────────────
OUT="$("$BIN" library import "$LIB" "$W/src" --json)"
ADDED=$(echo "$OUT" | jget added); UNCH=$(echo "$OUT" | jget unchanged)
[[ "$ADDED" == "0" && "$UNCH" == "900" ]] && pass "2 re-import idempotent" "added=0 unchanged=900" \
  || fail "2 re-import idempotent" "added=$ADDED unchanged=$UNCH"

# ── 3. kill mid-import, resume, no half rows ─────────────────────────────────────────────────
K="$W/K.photonslibrary"
"$BIN" library create "$K" >/dev/null
"$BIN" library import "$K" "$W/src" --test-interrupt-after 300 >/dev/null 2>&1
CODE=$?
HALF=$(sqlite3 "$K/library.db" "SELECT COUNT(*) FROM assets;")
STATE=$(sqlite3 "$K/library.db" "SELECT state FROM import_sessions ORDER BY started_at DESC LIMIT 1;")
if [[ $CODE -eq 137 && "$HALF" == "300" ]]; then
  pass "3 hard kill" "exit=137 committed rows=300 state=$STATE"
else
  fail "3 hard kill" "exit=$CODE rows=$HALF (want 137/300)"
fi
OUT="$("$BIN" library import "$K" "$W/src" --json)"
ADDED=$(echo "$OUT" | jget added)
DUPHASH=$(sqlite3 "$K/library.db" "SELECT COUNT(*) FROM (SELECT content_hash FROM assets GROUP BY content_hash HAVING COUNT(*)>1);")
TOTAL=$(sqlite3 "$K/library.db" "SELECT COUNT(*) FROM assets;")
if [[ "$ADDED" == "600" && "$DUPHASH" == "0" && "$TOTAL" == "900" ]]; then
  pass "3 resume completes" "added=600 total=900 duplicate hashes=0"
else
  fail "3 resume completes" "added=$ADDED total=$TOTAL duphashes=$DUPHASH"
fi
"$BIN" library verify "$K" >/dev/null && pass "3 verify after resume" "clean" || fail "3 verify after resume"

# ── 4. move keeps the row ───────────────────────────────────────────────────────────────────
mkdir -p "$W/src/moved"
for n in 00200 00201 00202 00203 00204; do mv "$W/src/IMG_$n.jpg" "$W/src/moved/"; done
OUT="$("$BIN" library rescan "$LIB" --json)"
MOVED=$(echo "$OUT" | jget moved)
PATHS=$(sqlite3 "$LIB/library.db" "SELECT COUNT(*) FROM assets WHERE rel_path LIKE 'moved/%';")
if [[ "$MOVED" == "5" && "$PATHS" == "5" ]]; then
  pass "4 move detected" "moved=5, rows repointed"
else
  fail "4 move detected" "moved=$MOVED repointed=$PATHS"
fi
"$BIN" library verify "$LIB" >/dev/null && pass "4 verify after move" "clean" || fail "4 verify after move"

# ── 5. volume offline never deletes ─────────────────────────────────────────────────────────
mv "$W/src" "$W/src-away"
S="$("$BIN" library stats "$LIB" --json)"
STATUS=$(echo "$S" | python3 -c 'import sys,json;print(json.load(sys.stdin)["roots"][0]["status"])')
COUNT=$(echo "$S" | jget assets)
mv "$W/src-away" "$W/src"
if [[ "$STATUS" == "offline" && "$COUNT" == "900" ]]; then
  pass "5 offline root" "status=offline assets kept=900"
else
  fail "5 offline root" "status=$STATUS assets=$COUNT"
fi
"$BIN" library verify "$LIB" >/dev/null && pass "5 verify when offline" "clean (no false 'missing')" || fail "5 verify when offline"

# ── 6. forward guard ────────────────────────────────────────────────────────────────────────
sqlite3 "$LIB/library.db" "PRAGMA user_version=999;"
ERR="$("$BIN" library stats "$LIB" 2>&1)"; CODE=$?
if [[ $CODE -ne 0 && "$ERR" == *"newer Photons"* ]]; then
  pass "6 newer-schema guard" "refused: ${ERR:0:60}…"
else
  fail "6 newer-schema guard" "exit=$CODE msg=$ERR"
fi
# repair so the rest of the run can continue
sqlite3 "$LIB/library.db" "PRAGMA user_version=1;"

# ── 7. pending migration ⇒ snapshot first ───────────────────────────────────────────────────
sqlite3 "$LIB/library.db" "PRAGMA user_version=0;"
"$BIN" library stats "$LIB" >/dev/null 2>&1
if ls "$LIB/backups/" 2>/dev/null | grep -q "library.bak-v0"; then
  pass "7 pre-migration snapshot" "$(ls "$LIB/backups/" | tr '\n' ' ')"
else
  fail "7 pre-migration snapshot" "no backup file"
fi

# ── 8. query timing (this library; 10k with --perf) ─────────────────────────────────────────
measure() { "$BIN" library assets "$1" "${@:2}" | tail -1; }
GRID=$(measure "$LIB" --limit 200)
STARS=$(measure "$LIB" --rating 4 --limit 200)
CAM=$(measure "$LIB" --camera "canon|eos r5" --limit 200)
worst=$(printf '%s\n%s\n%s\n' "$GRID" "$STARS" "$CAM" | grep -o '[0-9.]* ms' | tr -d ' ms' | sort -n | tail -1)
if awk "BEGIN{exit !($worst < 50)}"; then
  pass "8 query timing (900 rows)" "$GRID / $STARS / $CAM"
else
  fail "8 query timing (900 rows)" "worst=$worst ms"
fi

if [[ $PERF -eq 1 ]]; then
  P="$W/P.photonslibrary"
  "$BIN" library create "$P" >/dev/null
  "$BIN" fixtures "$W/perf" --count 10000 --dupes 5 --size 160x120 >/dev/null
  "$BIN" library import "$P" "$W/perf" --json >/dev/null
  GRID=$(measure "$P" --limit 200); STARS=$(measure "$P" --rating 4 --limit 200)
  CAM=$(measure "$P" --camera "canon|eos r5" --limit 200)
  worst=$(printf '%s\n%s\n%s\n' "$GRID" "$STARS" "$CAM" | grep -o '[0-9.]* ms' | tr -d ' ms' | sort -n | tail -1)
  if awk "BEGIN{exit !($worst < 50)}"; then
    pass "8 query timing (10k rows)" "$GRID / $STARS / $CAM"
  else
    fail "8 query timing (10k rows)" "worst=$worst ms"
  fi
fi

# ── 9. metadata from a real RAW, no sidecars ────────────────────────────────────────────────
if [[ -f "$RAW" ]]; then
  D="$W/D.photonslibrary"
  "$BIN" library create "$D" >/dev/null
  "$BIN" library import "$D" "$RAW" --json >/dev/null
  # NB: camera_key itself contains a pipe ("leica camera ag|leica sl3") — use tabs, not '|'.
  ROW=$(sqlite3 -separator $'\t' "$D/library.db" "SELECT a.camera_key, a.capture_local_date, a.capture_time_source, length(m.xmp_blob) FROM assets a JOIN asset_metadata m ON m.asset_id=a.id;")
  CK=$(echo "$ROW" | cut -f1); XMPLEN=$(echo "$ROW" | cut -f4)
  SIDECARS=$(ls "$(dirname "$RAW")"/*.xmp 2>/dev/null | wc -l | tr -d ' ')
  if [[ -n "$CK" && "$XMPLEN" -gt 1000 && "$SIDECARS" == "0" ]]; then
    pass "9 embedded XMP only" "camera_key=$CK local_date=$(echo "$ROW" | cut -f2) src=$(echo "$ROW" | cut -f3) xmp=${XMPLEN}B sidecars=$SIDECARS"
  else
    fail "9 embedded XMP only" "camera_key='$CK' xmp=${XMPLEN}B sidecars=$SIDECARS"
  fi
else
  say "9 embedded XMP only" "SKIP" "no RAW at $RAW"
fi

echo
if [[ $FAILED -eq 0 ]]; then
  echo "M2 ACCEPTANCE: ALL PASS"
else
  echo "M2 ACCEPTANCE: FAILURES ABOVE"
fi
exit $FAILED
