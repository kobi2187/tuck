#!/bin/bash
# `interface` — a compile-time contract (spec §5.2).
#
# Phase 1: the declaration and the check. An interface names a set of function
# signatures; an object declares `satisfies I` in its body and the compiler
# verifies it implements every one of them. No dispatch, no collections — those
# depend on a decision (heterogeneous `Seq[Animal]` or contract-only) that is
# deliberately still open, and nothing here forecloses it.
#
# Conformance rules:
#   - params and return match EXACTLY, names included (payload fields bind by
#     name, so a name is part of the contract)
#   - effects may be a SUBSET: an impl may do less than the contract permits,
#     never more
#   - `Self` in a required sig means the implementing type
cd "$(dirname "$0")/.."
. tests/lib.sh

# --- conformance passes ---------------------------------------------------

src <<'EOF'
interface Speaker:
  fn speak({volume: int}) -> str

object Dog:
  satisfies Speaker
  name: str

  fn speak({volume: int}) -> str:
    return self.name

fn main() -> int:
  return 0
EOF
ok_check "an object implementing every member satisfies"

# Several interfaces on one object — it is a seq of names, not a single slot.
src <<'EOF'
interface Speaker:
  fn speak({volume: int}) -> str

interface Named:
  fn label() -> str

object Dog:
  satisfies Speaker
  satisfies Named
  name: str

  fn speak({volume: int}) -> str:
    return self.name
  fn label() -> str:
    return self.name

fn main() -> int:
  return 0
EOF
ok_check "one object may satisfy several interfaces"

# Effects SUBSET: the contract permits [io], the impl is pure. Legal — an
# implementation may do less than the contract allows.
src <<'EOF'
interface Loader:
  fn load({path: str}) -> str [io]

object Cache:
  satisfies Loader
  data: str

  fn load({path: str}) -> str:
    return self.data

fn main() -> int:
  return 0
EOF
ok_check "an impl may declare fewer effects than the contract"

# `Self` in the contract reads as the implementing type.
src <<'EOF'
interface Cloneable:
  fn copyOf() -> Self

object Doc:
  satisfies Cloneable
  n: int

  fn copyOf() -> Doc:
    return self

fn main() -> int:
  return 0
EOF
ok_check "Self in a required sig means the implementing type"

# An interface nobody satisfies is still a legal declaration.
src <<'EOF'
interface Storable:
  fn save({dest: str}) -> int

fn main() -> int:
  return 0
EOF
ok_check "an unsatisfied interface is legal"

# --- conformance fails, with a message worth reading ----------------------

src <<'EOF'
interface Speaker:
  fn speak({volume: int}) -> str

object Mime:
  satisfies Speaker
  name: str

fn main() -> int:
  return 0
EOF
bad_check "a missing member is reported" "speak"

# The parameter NAME is part of the contract: payload fields bind by name, so
# renaming one silently changes how callers must write the call.
src <<'EOF'
interface Speaker:
  fn speak({volume: int}) -> str

object Dog:
  satisfies Speaker
  name: str

  fn speak({loudness: int}) -> str:
    return self.name

fn main() -> int:
  return 0
EOF
bad_check "a renamed parameter is reported" "loudness|volume"

src <<'EOF'
interface Speaker:
  fn speak({volume: int}) -> str

object Dog:
  satisfies Speaker
  name: str

  fn speak({volume: str}) -> str:
    return self.name

fn main() -> int:
  return 0
EOF
bad_check "a wrong parameter type is reported" "volume"

src <<'EOF'
interface Speaker:
  fn speak({volume: int}) -> str

object Dog:
  satisfies Speaker
  name: str

  fn speak({volume: int}) -> int:
    return 1

fn main() -> int:
  return 0
EOF
bad_check "a wrong return type is reported" "return|str|int"

# Effects the other way: the contract is pure, the impl wants [io]. Illegal —
# an implementation may never do MORE than the contract permits.
src <<'EOF'
interface Pure:
  fn compute({n: int}) -> int

object Logger:
  satisfies Pure

  fn compute({n: int}) -> int [io]:
    return n

fn main() -> int:
  return 0
EOF
bad_check "an impl may not declare effects the contract lacks" "io|effect"

src <<'EOF'
object Dog:
  satisfies NoSuchInterface
  name: str

  fn speak({volume: int}) -> str:
    return self.name

fn main() -> int:
  return 0
EOF
bad_check "satisfying an undeclared interface is reported" "NoSuchInterface"

# A body-less member does not implement anything — it is a signature, and the
# object would have no code to run.
src <<'EOF'
interface Speaker:
  fn speak({volume: int}) -> str

object Dog:
  satisfies Speaker
  name: str

  fn speak({volume: int}) -> str

fn main() -> int:
  return 0
EOF
bad_check "a body-less member does not implement the contract" "speak"

# --- top-level `Obj satisfies Iface` --------------------------------------
#
# A CALLING module attaches an object it did not declare to a contract it did
# not declare, so a library type can be used through your interface without
# editing the library.

src <<'TUCKEOF'
import sys

interface Speaker:
  fn noise({self: Self}) -> int

interface Mover:
  fn steps({self: Self}) -> int

object Dog:
  name: str
  fn noise({self: Dog}) -> int:
    return 1
  fn steps({self: Dog}) -> int:
    return 4

object Cat:
  satisfies Speaker
  name: str
  fn noise({self: Cat}) -> int:
    return 41
  fn steps({self: Cat}) -> int:
    return 0

Dog satisfies [Speaker, Mover]
Cat satisfies [Speaker, Mover]

fn hear({a: Speaker}) -> int:
  return a.noise

fn main() -> void [io]:
  let d = {name: "rex"} Dog
  let c = {name: "tom"} Cat
  let total = {a: d} hear + {a: c} hear
  total sys::exit
TUCKEOF
runs "a top-level satisfies attaches an object to a contract" 42

# Re-stating a contract the object already declares is a NO-OP, not an error:
# a calling module cannot know what the library already promised. (Cat above
# declares `satisfies Speaker` in its body AND is listed again at top level.)

src <<'TUCKEOF'
interface Speaker:
  fn noise({self: Self}) -> int

object Dog:
  name: str

Dog satisfies Speaker

fn main() -> int:
  return 0
TUCKEOF
bad_check "an attached contract is still enforced" "does not implement"

src <<'TUCKEOF'
interface Speaker:
  fn noise({self: Self}) -> int

Ghost satisfies Speaker

fn main() -> int:
  return 0
TUCKEOF
bad_check "attaching to an undeclared object is reported" "not a declared object"

# --- contracts come before fields -----------------------------------------
#
# What an object PROMISES should be visible before its data, so a body reads
# "what is this for" before "what does it hold" and the promise cannot hide
# below a long field list.

src <<'TUCKEOF'
interface Speaker:
  fn noise({self: Self}) -> int

object Dog:
  name: str
  satisfies Speaker
  fn noise({self: Dog}) -> int:
    return 1

fn main() -> int:
  return 0
TUCKEOF
bad_check "a satisfies line after a field is rejected" "before the object's fields"

# --- the existing example must stay honest --------------------------------

# examples/04-sum-types-interface.tuck declares `interface Storable` with a
# bare body (no `require:`), which is exactly the shape spec §5.2 now
# specifies. Nothing satisfies it, which stays legal.
if ./tuck ch examples/04-sum-types-interface.tuck --root:"$(pwd)" \
     > "$_dir/ex04.log" 2>&1; then
  _ok "examples/04 still checks"
else
  _no "examples/04 still checks" "$(tail -2 "$_dir/ex04.log")"
fi

finish
