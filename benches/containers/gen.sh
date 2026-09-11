#!/usr/bin/env bash
# Emit one directory per pattern at a given N. Each backend needs its own
# directory because Odin compiles a directory as a package.
set -e
N=$1
OUT=$2
mkdir -p "$OUT"

mk() { mkdir -p "$OUT/$1"; cat > "$OUT/$1/b.tuck"; }

mk seq_push <<EOF
import seq
fn build({n: int}) -> int:
  var xs: Seq[int] = []
  for i in 0 .. n - 1:
    xs = {items: xs, value: i} push
  return xs.len
fn main() -> int:
  return {n: $N} build - $N
EOF

mk rec_thread <<EOF
import seq
type Bag:
  items: Seq[int]
fn addTo({b: Bag, value: int}) -> Bag:
  var xs = b.items
  xs = {items: xs, value: value} push
  return {items: xs} Bag
fn main() -> int:
  var bag: Bag = {items: []} Bag
  for i in 0 .. $N - 1:
    bag = {b: bag, value: i} addTo
  return bag.items.len - $N
EOF

mk chain_form <<EOF
import seq
type Bag:
  items: Seq[int]
fn addTo({b: Bag, value: int}) -> Bag:
  var xs = b.items
  xs = {items: xs, value: value} push
  return {items: xs} Bag
fn main() -> int:
  var bag: Bag = {items: []} Bag
  for i in 0 .. $N - 1:
    bag ..addTo {value: i}
  return bag.items.len - $N
EOF

mk generic_box <<EOF
import seq
type Box[T]:
  items: Seq[T]
fn add[T]({b: Box[T], value: T}) -> Box[T]:
  var xs = b.items
  xs = {items: xs, value: value} push
  return {items: xs} Box
fn main() -> int:
  var b: Box[int] = {items: []} Box
  for i in 0 .. $N - 1:
    b = {b: b, value: i} add
  return b.items.len - $N
EOF

mk two_fields <<EOF
import seq
type Pair:
  ks: Seq[int]
  vs: Seq[int]
fn put({p: Pair, k: int, v: int}) -> Pair:
  var a = p.ks
  var b = p.vs
  a = {items: a, value: k} push
  b = {items: b, value: v} push
  return {ks: a, vs: b} Pair
fn main() -> int:
  var p: Pair = {ks: [], vs: []} Pair
  for i in 0 .. $N - 1:
    p = {p: p, k: i, v: i} put
  return p.ks.len - $N
EOF

mk str_concat <<EOF
type Doc:
  text: str
fn addLine({d: Doc, s: str}) -> Doc:
  return {text: d.text + s} Doc
fn main() -> int:
  var d: Doc = {text: ""} Doc
  for i in 0 .. $N - 1:
    d = {d: d, s: "x"} addLine
  return d.text.len - $N
EOF

mk str_builder <<EOF
import seq
import str
type Builder:
  chunks: Seq[str]
fn add({b: Builder, text: str}) -> Builder:
  var xs = b.chunks
  xs = {items: xs, value: text} push
  return {chunks: xs} Builder
fn built({b: Builder}) -> str:
  return {parts: b.chunks, sep: ""} joinStr
fn main() -> int:
  var b: Builder = {chunks: []} Builder
  for i in 0 .. $N - 1:
    b = {b: b, text: "x"} add
  let out = {b: b} built
  return out.len - $N
EOF

mk seq_setat <<EOF
import seq
type Bag:
  items: Seq[int]
fn bump({b: Bag, at: int}) -> Bag:
  var xs = b.items
  xs[at] = xs[at] + 1
  return {items: xs} Bag
fn seed({n: int}) -> Seq[int]:
  var xs: Seq[int] = []
  for i in 0 .. n - 1:
    xs = {items: xs, value: 0} push
  return xs
fn main() -> int:
  var bag: Bag = {items: {n: 64} seed} Bag
  for i in 0 .. $N - 1:
    bag = {b: bag, at: 0} bump
  return bag.items[0] - $N
EOF

mk read_only <<EOF
import seq
type Bag:
  items: Seq[int]
fn total({b: Bag}) -> int:
  var sum = 0
  for i in 0 .. b.items.len - 1:
    sum = sum + b.items[i]
  return sum
fn seed({n: int}) -> Seq[int]:
  var xs: Seq[int] = []
  for i in 0 .. n - 1:
    xs = {items: xs, value: 1} push
  return xs
fn main() -> int:
  let bag: Bag = {items: {n: 2000} seed} Bag
  var acc = 0
  for i in 0 .. $N - 1:
    acc = acc + {b: bag} total
  return acc - $N * 2000
EOF
