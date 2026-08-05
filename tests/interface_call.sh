#!/bin/bash
# Calling a method through an interface value (spec §5.3).
#
# `a.noise` where `a` is an interface parameter must resolve against the
# CONTRACT, not by bare name. Without an arm for it, synthFieldAccess fell
# through to asFnByName, which looked `noise` up in the flat signature table,
# found whichever object declared one, and rejected the receiver:
#
#   Type Error: argument to 'noise' expects Dog but got Animal
#
# The contract is what the callee can rely on: it knows `a` satisfies Animal
# and nothing more.
cd "$(dirname "$0")/.."
. tests/lib.sh

# --- calling through the contract -----------------------------------------

src <<'EOF'
interface Animal:
  fn noise({self: Self}) -> int

object Dog:
  satisfies Animal
  name: str

  fn noise({self: Dog}) -> int:
    return 1

fn hear({a: Animal}) -> int:
  return a.noise

fn main() -> int:
  return 0
EOF
ok_check "a contract member is callable through an interface value"

# The return type comes from the contract.
src <<'EOF'
interface Animal:
  fn noise({self: Self}) -> int

object Dog:
  satisfies Animal
  name: str

  fn noise({self: Dog}) -> int:
    return 1

fn hear({a: Animal}) -> str:
  return a.noise

fn main() -> int:
  return 0
EOF
bad_check "the contract's return type is enforced" "int|str|noise"

# A member the contract does not declare is not reachable, even when the
# concrete object happens to have one — the callee cannot know which object
# it was handed.
src <<'EOF'
interface Animal:
  fn noise({self: Self}) -> int

object Dog:
  satisfies Animal
  name: str

  fn noise({self: Dog}) -> int:
    return 1
  fn fetch({self: Dog}) -> int:
    return 2

fn hear({a: Animal}) -> int:
  return a.fetch

fn main() -> int:
  return 0
EOF
bad_check "a member outside the contract is not reachable" "fetch|Animal"

# Two objects, one interface parameter, called through the contract — the
# shape the feature exists for.
src <<'EOF'
interface Animal:
  fn noise({self: Self}) -> int

object Dog:
  satisfies Animal
  name: str
  fn noise({self: Dog}) -> int:
    return 1

object Cat:
  satisfies Animal
  lives: int
  fn noise({self: Cat}) -> int:
    return 41

fn hear({a: Animal}) -> int:
  return a.noise

fn main() -> int:
  var d = {name: "rex"} Dog
  var c = {lives: 9} Cat
  return ({a: d} hear) + ({a: c} hear)
EOF
ok_check "two objects reach one interface call site"

finish
