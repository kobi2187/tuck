#!/bin/bash
# The Benchmarks Game in Tuck: build each program on Nim, Odin and D in
# release mode, check its output against the C reference, and time the
# best of three runs against C.
#
#   benches/game/run.sh                 every program
#   benches/game/run.sh nbody           one
#
# The programs are written as Tuck is meant to be written, and are NOT
# tuned. When one is slow, the fix goes into the compiler (a transformation,
# a deduction, a runtime primitive), so every Tuck program gets it — see
# README.md, and SCORES.md for the ledger.
#
# Each program directory holds <name>.tuck, <name>.c and a `size` file: the
# argument to time at (the first line) and to check correctness at (second).
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
tuck="$root/tuck"
out="${TMPDIR:-/tmp}/tuck-game"
mkdir -p "$out"

best_of_3() {          # best_of_3 <exe> <arg>  -> seconds
  local best=""
  for _ in 1 2 3; do
    local s t x
    s=$(date +%s.%N); "$1" "$2" > /dev/null; t=$(date +%s.%N)
    x=$(echo "$t - $s" | bc)
    if [ -z "$best" ] || [ "$(echo "$x < $best" | bc)" = 1 ]; then best=$x; fi
  done
  printf "%.3f" "$best"
}

progs=("$@")
[ ${#progs[@]} -eq 0 ] && progs=($(cd "$here" && ls -d */ | tr -d /))
printf "%-16s %8s %16s %16s %16s\n" program C Nim Odin D
for p in "${progs[@]}"; do
  dir="$here/$p"; o="$out/$p"; mkdir -p "$o"
  timeArg=$(sed -n 1p "$dir/size"); checkArg=$(sed -n 2p "$dir/size")
  gcc -O2 -o "$o/ref" "$dir/$p.c" -lm || { echo "$p: C build failed"; continue; }
  want=$("$o/ref" "$checkArg")
  c=$(best_of_3 "$o/ref" "$timeArg")
  row=$(printf "%-16s %8s" "$p" "$c")
  for b in nim odin d; do
    flag=""; suf=""
    [ $b = odin ] && flag=--odin && suf=_odin
    [ $b = d ] && flag=--dlang && suf=_d
    if ! "$tuck" b "$dir/$p.tuck" $flag --release --max-fn-lines:0 \
         --max-complexity:0 --stdlib:stdlib-project --root:"$root" -o:"$o" \
         > "$o/build_$b.log" 2>&1; then
      row="$row $(printf "%16s" "BUILD FAILED")"; continue
    fi
    exe="$o/$p$suf"
    if [ "$("$exe" "$checkArg")" != "$want" ]; then
      row="$row $(printf "%16s" "WRONG OUTPUT")"; continue
    fi
    t=$(best_of_3 "$exe" "$timeArg")
    row="$row $(printf "%16s" "$t ($(echo "scale=1; $t / $c" | bc)x)")"
  done
  echo "$row"
done
