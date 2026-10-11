#!/bin/bash
# What the ownership rules' explicit drops cost, per backend: each app built
# --release, run best of 3 (time and peak RSS). No backend has a collector or
# a reference count since 2026-10-11 (Nim --mm:none, D with the collector
# off, Odin never had one), so there is one column per backend. Compare with
# the 2026-10-11 first entry in SCORES.md, where Nim ran ARC and D the GC.
OUT=${OUT:-$(mktemp -d)}
cd "$(dirname "$0")/.."
peakrun() {  # cmd... -> "ms peakMB rc"
  local peak=0 cur t0 t1 rc
  t0=$(date +%s%N); "$@" >/dev/null 2>&1 & local pid=$!
  while kill -0 $pid 2>/dev/null; do
    cur=$(awk '/VmHWM/{print $2}' /proc/$pid/status 2>/dev/null); [ -n "$cur" ] && [ "$cur" -gt "$peak" ] && peak=$cur; sleep 0.005
  done
  wait $pid; rc=$?; t1=$(date +%s%N)
  echo "$(( (t1 - t0) / 1000000 )) $((peak/1024)) $rc"
}
best() { # label cmd...
  local lab=$1; shift; local b=999999 bp=0 brc=
  for i in 1 2 3; do read ms mb rc < <(peakrun "$@"); [ $ms -lt $b ] && { b=$ms; bp=$mb; brc=$rc; }; done
  printf "%-34s %7d ms %6d MB  rc=%s\n" "$lab" $b $bp $brc
}
bin() { find $1 -maxdepth 1 -type f -perm -u+x ! -name '*.o' ! -name '*.a' | head -1; }
for app in matching_engine world_server; do
  d=$OUT/$app; rm -rf $d; mkdir -p $d/{nim,odin,dl}
  ./tuck b benches/apps/$app.tuck --release -o:$d/nim >/dev/null 2>&1 || echo "$app nim: build failed"
  ./tuck b benches/apps/$app.tuck --release --odin -o:$d/odin >/dev/null 2>&1 || echo "$app odin: build failed"
  ./tuck b benches/apps/$app.tuck --release --dlang -o:$d/dl >/dev/null 2>&1 || echo "$app d: build failed"
  best "$app nim (--mm:none)" $(bin $d/nim)
  best "$app odin" $(bin $d/odin)
  best "$app d (collector off)" $(bin $d/dl)
done
