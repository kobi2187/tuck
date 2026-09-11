#!/usr/bin/env bash
# Container-copy benches. Each pattern is built at N and 2N; the RATIO is the
# reading — ~2 is linear, ~4 is a copy per iteration.
#
#   bash benches/containers/run.sh [N]
set -u
cd "$(dirname "$0")"
N=${1:-20000}
N2=$((N * 2))
TUCK=../../tuck
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

./gen.sh "$N"  "$WORK/a" >/dev/null
./gen.sh "$N2" "$WORK/b" >/dev/null

secs() {  # dir backend suffix -> seconds, or "-" if it did not build/run
  local d=$1 flag=$2 sfx=$3
  timeout 240 "$TUCK" b "$d/b.tuck" $flag --release >/dev/null 2>&1 || { echo "-"; return; }
  local bin="$d/b$sfx"
  [ -x "$bin" ] || { echo "-"; return; }
  local t0 t1
  t0=$(date +%s.%N)
  timeout 240 "$bin" >/dev/null 2>&1 || { echo "-"; return; }
  t1=$(date +%s.%N)
  echo "$t1 $t0" | awk '{printf "%.2f", $1-$2}'
}

row() {  # name flag suffix
  local p=$1 flag=$2 sfx=$3
  local t1 t2 ratio
  t1=$(secs "$WORK/a/$p" "$flag" "$sfx")
  t2=$(secs "$WORK/b/$p" "$flag" "$sfx")
  if [ "$t1" = "-" ] || [ "$t2" = "-" ]; then ratio="-"
  else ratio=$(echo "$t2 $t1" | awk '{ if ($2+0 < 0.02) print "~0"; else printf "%.1f", $1/$2 }'); fi
  printf "%-8s %7s %7s %7s" "$sfx" "$t1" "$t2" "$ratio"
}

echo "N=$N vs N=$N2   (ratio ~2 = linear, ~4 = a copy per iteration)"
printf "\n%-14s %-8s %7s %7s %7s\n" "pattern" "backend" "t(N)" "t(2N)" "ratio"
for p in seq_push rec_thread chain_form generic_box two_fields str_concat seq_setat read_only; do
  printf "%-14s " "$p";      row "$p" ""        ""
  printf "\n%-14s " "";      row "$p" "--odin"  "_odin"
  printf "\n%-14s " "";      row "$p" "--dlang" "_d"
  echo
done
