#!/bin/bash
# Stackless spike (#216): build the stackful baselines with `tuck b --release`
# and the hand-lowered stackless versions with the same Nim flags, then print
# both. Builds in a scratch dir: `tuck b` writes next to its source.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../.."
out="${TMPDIR:-/tmp}/tuck-stackless-spike"
mkdir -p "$out"
cp "$here"/b_await.tuck "$here"/b_chain.tuck "$out"/
F="--hints:off --warnings:off --mm:none -d:useMalloc --exceptions:goto --stackTrace:off --lineTrace:off --threads:on -d:release --passC:-flto --passL:-flto --overflowChecks:off"
command -v clang >/dev/null && F="$F --cc:clang"
ms() { local s e; s=$(date +%s%N); "$@"; e=$(date +%s%N); echo $(( (e - s) / 1000000 )); }

echo "=== stackful (today: minicoro) ==="
(cd "$out" && "$root/tuck" b b_await.tuck --release --max-fn-lines:0 >/dev/null \
            && "$root/tuck" b b_chain.tuck --release --max-fn-lines:0 >/dev/null)
echo "b_await   1M spawn+await: $(ms "$out/b_await") ms"
echo "b_chain   10M yield+call: $(ms "$out/b_chain") ms"
nim c $F --nimcache:"$out/nc_bas" -o:"$out/bas" "$root/benches/bench_async_scale.nim" >/dev/null
"$out/bas" 10000 100

echo "=== stackless (hand-lowered) ==="
nim c $F --nimcache:"$out/nc_sl" -o:"$out/bsl" "$here/bench_stackless.nim" >/dev/null
"$out/bsl"
