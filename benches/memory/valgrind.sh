#!/usr/bin/env bash
# MEMORY CORRECTNESS, ACROSS BACKENDS — the six stress programs under
# valgrind's memcheck, with the collectors OFF where there is one.
#
#   bash benches/memory/valgrind.sh [N]      # default N=2000
#
# run.sh measures how much memory a backend holds; this says whether what it
# does with it is RIGHT: no read or write of freed or uninitialised memory,
# and no block left unfreed. A collector gets in memcheck's way, so each
# backend runs in the configuration that lets memcheck see it:
#
#   nim       ORC, `-d:useMalloc` — every allocation a real malloc/free
#             memcheck can pair up. Should end with nothing lost.
#   nim-none  `--mm:none -d:useMalloc` — nothing is ever freed, so "lost" is
#             every byte the program allocated: the work a memory manager
#             (or the ownership pass) has to undo.
#   odin      as it ships: no collector, only the `delete`s the ownership
#             pass decided. Should end with nothing lost.
#   d-nogc    `--DRT-gcopt=disable:1`. D's collector scans memory
#             conservatively, which memcheck reports as reads of
#             uninitialised values; with collection off nothing scans, so an
#             error left is a real one. Its heap is the GC's own mmapped
#             pools, invisible to memcheck, so D has no leak column.
#
# Columns: INVALID accesses and frees (a wrong program), all memcheck errors
# (including allocator-internal uninitialised-value noise), bytes definitely
# lost, and malloc/free counts.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE/../.."
N=${1:-2000}
TUCK=${TUCK:-$PWD/tuck}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

command -v valgrind >/dev/null || { echo "valgrind not found"; exit 2; }

. "$HERE/programs.sh"
gen "$WORK" "$N"

VARIANTS=(
  "nim|--nim:-d:useMalloc||"
  "nim-none|--nim:--mm:none -d:useMalloc||"
  "odin|--odin|_odin|"
  "d-nogc|--dlang|_d|--DRT-gcopt=disable:1"
)

check() {  # dir label flags suffix runargs -> one table row
  local d=$1 label=$2 flags=$3 sfx=$4 runargs=$5
  local out="$d/out${flags//[^a-z]/_}"
  # Each variant's flags are ONE tuck option (`--nim:...` may hold spaces).
  timeout 300 "$TUCK" b "$d/b.tuck" ${flags:+"$flags"} --release \
    --max-fn-lines:0 --max-complexity:0 -o:"$out" >/dev/null 2>&1
  if [ ! -x "$out/b$sfx" ]; then
    printf "%-9s %8s\n" "$label" "no build"
    return
  fi
  local log="$out/vg.log" rc
  # shellcheck disable=SC2086  # runargs is empty or one word, on purpose
  timeout 600 valgrind --leak-check=full --error-exitcode=99 \
    --log-file="$log" "$out/b$sfx" $runargs >/dev/null 2>&1
  rc=$?
  local errors invalid lost allocs frees
  errors=$(awk '/ERROR SUMMARY/ {print $4; exit}' "$log")
  # The errors that mean a WRONG PROGRAM: touching memory that is not the
  # program's (freed, out of bounds) or freeing what is not allocated. The
  # rest are "uninitialised value" reports, and Odin's own allocator makes
  # those on every growth of a dynamic array — a plain Odin `append` loop
  # with no Tuck in it reports the same — so they are counted apart.
  invalid=$(grep -cE "Invalid (read|write|free)|Mismatched free|Source and destination overlap" "$log")
  lost=$(awk '/definitely lost:/ {gsub(",", "", $4); print $4; exit}' "$log")
  allocs=$(awk '/total heap usage/ {gsub(",", "", $5); print $5; exit}' "$log")
  frees=$(awk '/total heap usage/ {gsub(",", "", $7); print $7; exit}' "$log")
  [ "$label" = "d-nogc" ] && lost="n/a"
  local verdict="ok"
  [ "$rc" -ne 0 ] && [ "$rc" -ne 99 ] && verdict="exit $rc"
  printf "%-9s %8s %8s %12s %10s %10s  %s\n" "$label" "${invalid:-?}" \
         "${errors:-?}" "${lost:-0}" "${allocs:-?}" "${frees:-?}" "$verdict"
}

echo "valgrind memcheck, N=$N, release builds"
printf "\n%-11s %-9s %8s %8s %12s %10s %10s\n" \
       "pattern" "variant" "invalid" "all errs" "lost bytes" "mallocs" "frees"
for p in ${PATTERNS:-copy_loop chain overwrite value_copy transfer str_temps}; do
  name=$p
  for spec in "${VARIANTS[@]}"; do
    IFS='|' read -r label flags sfx runargs <<< "$spec"
    printf "%-11s " "$name"
    check "$WORK/$p" "$label" "$flags" "$sfx" "$runargs"
    name=""
  done
done
