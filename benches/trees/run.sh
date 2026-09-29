#!/usr/bin/env bash
# Tree benches: a recursive sum built to depth D and evaluated ROUNDS times,
# on every backend, at D and D+1 (twice the nodes). The RATIO is the reading:
# ~2 is linear, ~4 is a copy per step.
#
#   bash benches/trees/run.sh [DEPTH] [ROUNDS]
#
# boxed.tuck        the tree as an author writes it (lowering_recursive boxes
#                   each edge in a one-element Seq)
# slab_merge.tuck   one node array per tree value, children as indices — what
#                   a slab lowering of the same constructions would produce
# slab_thread.tuck  one node array threaded through the whole build
#
# repr.nim holds the representation question alone, hand-written in Nim:
#   nim c -d:release --mm:orc repr.nim && ./repr 20
set -u
cd "$(dirname "$0")"
D=${1:-14}; K=${2:-10}; D2=$((D + 1))
TUCK=../../tuck
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

secs() {  # variant depth flag -> seconds, or BUILD / rc=N
  local v=$1 d=$2 flag=$3 leaves=$((1 << $2))
  local src=$WORK/${v}_$d.tuck out=$WORK/o_${v}_${d}${flag}
  sed "s/DEPTH/$d/; s/ROUNDS/$K/g; s/LEAVES/$leaves/" "$v.tuck" > "$src"
  timeout 600 "$TUCK" b "$src" $flag --release --max-fn-lines:0 \
      --max-complexity:0 -o:"$out" >/dev/null 2>&1 || { echo BUILD; return; }
  local bin
  bin=$(ls "$out"/${v}_$d* | grep -vE '\.(nim|odin|d|o|a)$' | head -1)
  local t0 t1 rc
  t0=$(date +%s.%N); timeout 300 "$bin" >/dev/null 2>&1; rc=$?; t1=$(date +%s.%N)
  [ $rc -ne 0 ] && { echo "rc=$rc"; return; }
  echo "$t1 $t0" | awk '{printf "%.3f", $1-$2}'
}

echo "depth $D vs $D2, $K rounds   (ratio ~2 = linear, ~4 = a copy per step)"
printf "\n%-12s %-6s %8s %8s %6s\n" variant backend "t(D)" "t(D+1)" ratio
for v in boxed slab_merge slab_thread; do
  for flag in "" --odin --dlang; do
    a=$(secs $v $D "$flag"); b=$(secs $v $D2 "$flag")
    r=$(echo "$b $a" | awk '{ if ($2+0 < 0.005 || $1 !~ /^[0-9.]+$/) print "-"; else printf "%.1f", $1/$2 }')
    printf "%-12s %-6s %8s %8s %6s\n" $v "${flag:-nim}" "$a" "$b" "$r"
  done
done
