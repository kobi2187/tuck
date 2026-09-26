# benches/memory/programs.sh — the six stress programs, one per heap path the
# ownership pass decides. Sourced by run.sh (time and peak RSS per backend)
# and valgrind.sh (leaks and invalid accesses); `gen DIR N` writes them.
#
# --- the programs --------------------------------------------------------------
#
# One directory per pattern and size: Odin compiles a directory as a package.
gen() {  # dir n
  local out=$1 n=$2
  mk() { mkdir -p "$out/$1"; cat > "$out/$1/b.tuck"; }

  # #77's shape. A copy per turn that the binding must make, and the old
  # value freed at the OVERWRITE (fkOverwrite): 1024 ints per turn.
  mk copy_loop <<EOF
import seq

fn zeroed({levels: int}) -> Seq[int]:
  var out = [0]
  var i = 1
  for i < levels:
    out = {items: out, value: 0} push
    i = i + 1
  return out

fn bump({xs: Seq[int]}) -> Seq[int]:
  var ys = xs
  ys[0] = ys[0] + 1
  return ys

fn main() -> int:
  var xs = {levels: 1024} zeroed
  var i = 0
  for i < $n:
    let ns = {xs: xs} bump
    xs = ns
    i = i + 1
  if xs[0] != $n:
    return 1
  return 0
EOF

  # #82's shape. A record with two Seq fields threaded through two MOVED
  # twins; one field of the last result is kept. Each twin frees the slots
  # it does not hand on (fkTwinParam, per slot); each local frees the slots
  # that do not escape (fkScopeExit, per slot).
  mk chain <<EOF
import seq

type Flood:
  height: Seq[int]
  light:  Seq[int]
  n:      int

fn zeroed({levels: int}) -> Seq[int]:
  var out = [0]
  var i = 1
  for i < levels:
    out = {items: out, value: 0} push
    i = i + 1
  return out

fn step({f: Flood}) -> Flood:
  var l = f.light
  l[0] = l[0] + 1
  return {height: f.height, light: l, n: f.n + 1} Flood

fn relight({h: Seq[int], l: Seq[int]}) -> Seq[int]:
  let a = {height: h, light: l, n: 0} Flood
  let b = {f: a} step
  let c = {f: b} step
  return c.light

fn main() -> int:
  let h = {levels: 1024} zeroed
  let l = {levels: 1024} zeroed
  var i = 0
  var acc = 0
  for i < $n:
    let out = {h: h, l: l} relight
    acc = acc + out[0]
    i = i + 1
  if acc != 2 * $n:
    return 1
  return 0
EOF

  # A value overwritten by one built FROM it: the old buffer must die after
  # the replacement is built, not before (a use-after-free on Odin until
  # 2026-09-25). 256 pushes per turn, so the in-place append is in it too.
  mk overwrite <<EOF
import seq

fn fresh({k: int, size: int}) -> Seq[int]:
  var out = [k]
  var i = 1
  for i < size:
    out = {items: out, value: k} push
    i = i + 1
  return out

fn main() -> int:
  var xs = {k: 0, size: 256} fresh
  var i = 0
  for i < $n:
    xs = {k: xs[0] + 1, size: 256} fresh
    i = i + 1
  if xs[0] != $n:
    return 1
  return 0
EOF

  # Value semantics that COSTS: `var t = xs` in the callee must copy (the
  # write to t may not reach the caller), and the copy is freed at scope
  # exit. The caller's value never changes.
  mk value_copy <<EOF
import seq

fn zeroed({levels: int}) -> Seq[int]:
  var out = [0]
  var i = 1
  for i < levels:
    out = {items: out, value: 0} push
    i = i + 1
  return out

fn poke({xs: Seq[int]}) -> int:
  var t = xs
  t[0] = t[0] + 1
  return t[0]

fn main() -> int:
  let xs = {levels: 1024} zeroed
  var i = 0
  var acc = 0
  for i < $n:
    acc = acc + {xs: xs} poke
    i = i + 1
  if xs[0] != 0 or acc != $n:
    return 1
  return 0
EOF

  # A local that TAKES a twin's parameter at its last read: no copy, and the
  # local is the buffer's only owner — freed once, not also by the twin.
  mk transfer <<EOF
import seq

fn fresh({k: int, size: int}) -> Seq[int]:
  var out = [k]
  var i = 1
  for i < size:
    out = {items: out, value: k} push
    i = i + 1
  return out

fn drop({xs: Seq[int]}) -> Seq[int]:
  let t = xs
  let n = t.len
  return {k: n, size: 64} fresh

fn main() -> int:
  var a = {k: 0, size: 64} fresh
  var i = 0
  for i < $n:
    a = {xs: a} drop
    i = i + 1
  if a[0] != 64:
    return 1
  return 0
EOF

  # Temporary strings: the runtime's allocating procs (toStr, concat) hand
  # back storage the caller owns, freed at scope exit.
  mk str_temps <<EOF
import str

fn main() -> int:
  var acc = 0
  var i = 0
  for i < $n * 10:
    let s = i.toStr
    let t = s + "-" + s
    acc = acc + t.len
    i = i + 1
  if acc < $n * 10:
    return 1
  return 0
EOF
}
