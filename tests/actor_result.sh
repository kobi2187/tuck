#!/bin/bash
# `result` inside an actor handler carries the handler's declared return type.
#
# It was bound to nothing at all, so it synthesized as Unknown — and Unknown is
# compatible with everything, so `result = <anything>` was accepted and every
# later use went unchecked. One of the five gaps that a strict-typing
# experiment surfaced; the sentinel had been hiding it.
cd "$(dirname "$0")/.."
. tests/lib.sh

src <<'EOF'
actor Counter:
  count: int = 0

  on get() -> {count: int}:
    result = {count}

fn main() -> int:
  return 0
EOF
ok_check "assigning the declared shape to result is fine"

src <<'EOF'
actor Counter:
  count: int = 0

  on get() -> {count: int}:
    result = "not a record"

fn main() -> int:
  return 0
EOF
try bad_check "assigning the wrong type to result is caught" "result|count|str"
bug_open "result is not typed (nothing binds it, so it synthesizes as Unknown)"

# A handler with no return type has no result to assign.
src <<'EOF'
actor Counter:
  count: int = 0

  on bump({n: int}):
    result = {count}

fn main() -> int:
  return 0
EOF
try bad_check "a void handler has no result" "result"
bug_open "a void handler's result is not rejected (same cause)"

# The actor's own fields still resolve inside a handler — a regression guard,
# since binding result must not disturb the field scope.
src <<'EOF'
actor Counter:
  count: int = 0

  on bump({n: int}):
    count += n

fn main() -> int:
  return 0
EOF
ok_check "actor fields still resolve in a handler"

# Assigning to a name nothing declares — not actor-specific, it is unchecked in
# a plain fn too. The assignment target synthesizes as Unknown and Unknown
# accepts anything, so the typo never surfaces.
src <<'EOF'
actor Counter:
  count: int = 0

  on bump({n: int}):
    nosuchfield += n

fn main() -> int:
  return 0
EOF
try bad_check "an unknown actor field is caught" "nosuchfield"
bug_open "an undeclared name is not caught (exkVar resolves to Unknown)"

src <<'EOF'
fn f({n: int}) -> void:
  nosuchvar += n

fn main() -> int:
  return 0
EOF
try bad_check "an undeclared assignment target is caught in a plain fn too" "nosuchvar"
bug_open "...and the same in a plain fn, which is where the real fix belongs"

finish
