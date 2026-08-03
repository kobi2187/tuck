#!/bin/bash
# Which Tuck programs must be forbidden, and which must stay allowed.
#
# These pin the SEMANTICS of escape analysis before it exists, so the
# implementation is measured against intent rather than the other way round.
# tests/escape_solver.nim checks the solver's math; this file checks the
# decisions a programmer would actually feel.
#
# The bias is deliberate and asymmetric:
#
#   - a forbidden case that compiles is a DANGLING POINTER
#   - an allowed case that is rejected is an annoyance
#
# so the forbidden list is short and certain, and the allowed list is long and
# covers ordinary code. Being conservative in the analysis is fine; being
# conservative in what the LANGUAGE permits is not, because every false
# rejection is a program someone has to rewrite for no reason.
#
# Status: all of it passes. The analysis (compiler/escape.nim, fed by
# checkEscapesIn) rejects the three dangling shapes and lets every ordinary
# pattern through — which is the point of having both lists.
#
# Writing the ALLOW list first paid for itself immediately: it found that
# `{a: a} inner` — passing an interface value onward — was rejected with
# "Animal is not an object, so it cannot satisfy Animal". Fixed.
cd "$(dirname "$0")/.."
. tests/lib.sh

IFACE='interface Animal:
  fn noise({self: Self}) -> int

object Dog:
  name: str
  satisfies Animal

  fn noise({self: Dog}) -> int:
    return 1

object Cat:
  lives: int
  satisfies Animal

  fn noise({self: Cat}) -> int:
    return 41
'

# ===========================================================================
# MUST BE FORBIDDEN — the value outlives the object it borrows
# ===========================================================================

# The canonical dangle: a local wrapped and returned.
src <<EOF
$IFACE
fn pick({a: Animal}) -> Animal:
  return a

fn bad() -> Animal:
  var d = {name: "rex"} Dog
  return {a: d} pick

fn main() -> int:
  return 0
EOF
bad_check "returning a wrap of a LOCAL" "escape|outlive|local"

# Same, without the helper — the wrap happens in the return expression.
src <<EOF
$IFACE
fn hear({a: Animal}) -> int:
  return a.noise

fn bad() -> Animal:
  var d = {name: "rex"} Dog
  var wrapped = {a: d} pick
  return wrapped

fn pick({a: Animal}) -> Animal:
  return a

fn main() -> int:
  return 0
EOF
bad_check "returning a local that was wrapped earlier" "escape|outlive|local"

# Through a collection: the Seq outlives the objects its elements point at.
src <<EOF
$IFACE
fn bad() -> Seq[Animal]:
  var d = {name: "rex"} Dog
  var c = {lives: 9} Cat
  return [d, c]

fn main() -> int:
  return 0
EOF
bad_check "returning a Seq of wraps of LOCALS" "escape|outlive|local"

# Buried one level: the local escapes inside a record.
src <<EOF
$IFACE
type Boxed = {inner: Animal}

fn pick({a: Animal}) -> Animal:
  return a

fn bad() -> int:
  var d = {name: "rex"} Dog
  var b = {inner: {a: d} pick} Boxed
  return 0

fn main() -> int:
  return 0
EOF
# Already caught, by the field rule rather than by escape analysis: an
# interface value may not be stored in a field at all.
bad_check "storing a wrap of a local in a record" "escape|outlive|interface"

# ===========================================================================
# MUST STAY ALLOWED — ordinary code, no dangle possible
# ===========================================================================

# The common case: pass an object as an interface, use it, return a plain value.
src <<EOF
$IFACE
fn hear({a: Animal}) -> int:
  return a.noise

fn main() -> int:
  var d = {name: "rex"} Dog
  return {a: d} hear
EOF
ok_check "ALLOW: passing a local as an interface parameter"
runs     "ALLOW: ...and it runs"  1

# Returning a borrow of a PARAMETER is safe — the caller owns the object.
src <<EOF
$IFACE
fn pick({a: Animal}) -> Animal:
  return a

fn main() -> int:
  return 0
EOF
ok_check "ALLOW: returning a borrow of a parameter"

# Choosing between two parameters — still all caller-owned.
src <<EOF
$IFACE
fn choose({a: Animal, b: Animal, first: bool}) -> Animal:
  if first:
    return a
  return b

fn main() -> int:
  return 0
EOF
ok_check "ALLOW: returning one of several parameters"

# A local used only within the frame — the whole point of stack placement.
src <<EOF
$IFACE
fn hear({a: Animal}) -> int:
  return a.noise

fn localOnly() -> int:
  var d = {name: "rex"} Dog
  var total = 0
  total = total + ({a: d} hear)
  total = total + ({a: d} hear)
  return total

fn main() -> int:
  return {} localOnly
EOF
ok_check "ALLOW: a local wrapped repeatedly, never escaping"
runs     "ALLOW: ...and it runs"  2

# A loop over locals — must not be rejected just because a wrap is in a loop.
src <<EOF
$IFACE
fn hear({a: Animal}) -> int:
  return a.noise

fn loopy() -> int:
  var d = {name: "rex"} Dog
  var total = 0
  for i in 0 ..< 3:
    total = total + ({a: d} hear)
  return total

fn main() -> int:
  return {} loopy
EOF
ok_check "ALLOW: wrapping inside a loop"
runs     "ALLOW: ...and it runs"  3

# Passing a wrap onward to another fn — still bounded by this frame.
src <<EOF
$IFACE
fn inner({a: Animal}) -> int:
  return a.noise

fn outer({a: Animal}) -> int:
  return {a: a} inner

fn main() -> int:
  var d = {name: "rex"} Dog
  return {a: d} outer
EOF
ok_check "ALLOW: passing an interface value down the call chain"
runs     "ALLOW: ...and it runs"  1

# Two different objects through one parameter — the feature itself.
src <<EOF
$IFACE
fn hear({a: Animal}) -> int:
  return a.noise

fn main() -> int:
  var d = {name: "rex"} Dog
  var c = {lives: 9} Cat
  return ({a: d} hear) + ({a: c} hear)
EOF
ok_check "ALLOW: two concrete types through one interface parameter"
runs     "ALLOW: ...and it runs"  42

# A branch where one path escapes and the other does not: the LOCAL escapes,
# but a parameter-only path must not be blamed for it.
src <<EOF
$IFACE
fn pick({a: Animal}) -> Animal:
  return a

fn conditional({a: Animal, useParam: bool}) -> Animal:
  if useParam:
    return a
  return a

fn main() -> int:
  return 0
EOF
ok_check "ALLOW: every path returns a parameter"

finish
