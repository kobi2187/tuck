#!/bin/bash
# Run Tuck programs under valgrind and report what they leak.
#
# WHY THIS IS NOT IN tests/run. Valgrind costs 20-50x, and the two leaks it
# finds are already pinned by `hostPeakRss` assertions in `known_bugs` that
# run in milliseconds. What valgrind adds is the ALLOCATION SITE, and that is
# worth having on demand rather than every commit: EV-20 was found by running
# this over the examples smallest-first, and the stack naming
# `os::read_entire_file_from_path` inside `tuckrt::fileWorker` is what turned
# "30 bytes somewhere" into "every heap str leaks".
#
# Usage:
#   tools/leakcheck.sh                      # every runnable example, Odin
#   tools/leakcheck.sh --nim                # ...on Nim instead
#   tools/leakcheck.sh --dlang f.tuck g.tuck
#   tools/leakcheck.sh --sites f.tuck       # print the leaking stacks
#
# WHAT A CLEAN RUN LOOKS LIKE, per backend, as of 2026-09-22:
#
#   nim    every example clean. Zero definitely lost; an actor program keeps
#          1 byte still reachable.
#   dlang  zero definitely lost from Tuck. A constant 32 bytes (80 with
#          actors) is druntime's own startup — `rt.minfo.sortCtors` under
#          `rt_init`, `rt.tlsgc.init` on thread entry, and the GC's
#          `initialize()`. Not ours, and not a function of the program.
#   odin   TWO leaks and one benign constant:
#            * issue #86 (EV-20) every heap `str`, linear in strings made.
#              Sites: `strings::Builder` (toStr, concat) and
#              `os::read_entire_file_from_path` (readFile).
#            * issue #82 (EV-14) `Seq` intermediates abandoned in a
#              threading chain. Site: `tuckrt::tuckSeqCopy`.
#            * 31 bytes, constant, per program: the `thread::Thread` from
#              `tuckStartActor`, never joined at exit. BY DESIGN — see the
#              "an idle actor does not keep a finished main alive" ruling —
#              and the OS reclaims it. Not a bug; do not chase it.
#
# So on Odin a NEW leak is one whose stack names none of those. That is the
# question this script exists to answer quickly.
set -u
cd "$(dirname "$0")/.."

bk="--odin"; sites=0; files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --nim)   bk="" ;;
    --odin)  bk="--odin" ;;
    --dlang) bk="--dlang" ;;
    --sites) sites=1 ;;
    *)       files+=("$1") ;;
  esac
  shift
done

if [ ${#files[@]} -eq 0 ]; then
  for f in examples/*.tuck; do
    grep -q "^fn main" "$f" && files+=("$f")
  done
fi

out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
tag="${bk:---nim}"; tag="${tag#--}"

for f in "${files[@]}"; do
  n=$(basename "$f" .tuck)
  d="$out/$n"
  if ! ./tuck b "$f" $bk -o:"$d" >/dev/null 2>&1; then
    printf "%-30s %-5s  build failed\n" "$n" "$tag"; continue
  fi
  bin=$(find "$d" -maxdepth 1 -type f -executable | head -1)
  [ -z "$bin" ] && { printf "%-30s %-5s  no binary\n" "$n" "$tag"; continue; }
  log="$d/vg.log"
  timeout 900 valgrind --leak-check=full --log-file="$log" "$bin" >/dev/null 2>&1

  if grep -q "All heap blocks were freed" "$log"; then
    printf "%-30s %-5s  clean (nothing allocated)\n" "$n" "$tag"; continue
  fi
  def=$(grep -oP 'definitely lost: \K[0-9,]+' "$log" | tr -d ,)
  ind=$(grep -oP 'indirectly lost: \K[0-9,]+' "$log" | tr -d ,)
  rch=$(grep -oP 'still reachable: \K[0-9,]+' "$log" | tr -d ,)
  lost=$(( ${def:-0} + ${ind:-0} ))
  printf "%-30s %-5s  lost=%-10s reachable=%s\n" "$n" "$tag" "$lost" "${rch:-0}"

  if [ "$sites" -eq 1 ] && [ "$lost" -gt 0 ]; then
    grep -A 14 "are definitely lost in loss record" "$log" \
      | grep -oP '(main|tuckrt|strings|os|thread|rt)::[A-Za-z_.:\[\]]+' \
      | sort -u | sed 's/^/      /'
  fi
done
