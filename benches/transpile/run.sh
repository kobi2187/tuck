#!/bin/bash
# What does the TRANSPILER cost?
#
# Every other bench in this directory measures the runtime — coroutines,
# actors, the offload worker. This one measures the gap between Tuck-emitted
# code and the code a programmer would have written by hand for the same job,
# in the same target language, with the same flags. It is the question
# "am I paying for the abstraction?" asked directly.
#
#   Run: bash benches/transpile/run.sh
set -e
cd "$(dirname "$0")"
NIMFLAGS="-d:release --hints:off --warnings:off --stackTrace:off --lineTrace:off"
TUCK=../../tuck

echo "=== building ==="
for k in payload record dispatch; do
  nim c $NIMFLAGS -o:.${k}_hand ${k}_hand.nim > /dev/null 2>&1
done
nim c $NIMFLAGS -o:.d_oop dispatch_oop.nim > /dev/null 2>&1
$TUCK b payload.tuck  --release                   > /dev/null 2>&1
$TUCK b record.tuck   --release                   > /dev/null 2>&1
# --max-fn-lines: the dispatch kernel needs one fn per shape branch to stay
# one basic block; the house limit of 8 is about readability, not this.
$TUCK b dispatch.tuck --release --max-fn-lines:20 > /dev/null 2>&1

echo "=== same answer? (a differing exit code means the kernels diverged) ==="
for p in payload record dispatch; do
  set +e; ./$p > /dev/null 2>&1; a=$?; ./.${p}_hand > /dev/null 2>&1; b=$?; set -e
  printf "  %-10s tuck %-3s hand %-3s %s\n" "$p" "$a" "$b" \
         "$([ "$a" = "$b" ] && echo ok || echo DIVERGED)"
done

echo "=== timings (best of 5) ==="
python3 time.py \
  "payload  tuck=./payload"        "payload  hand=./.payload_hand" \
  "record   tuck=./record"         "record   hand=./.record_hand" \
  "dispatch tuck=./dispatch"       "dispatch hand=./.dispatch_hand" \
  "dispatch nim methods=./.d_oop"
