## The resource registry — spec §7.4, issue #32. Build order and the settled
## design questions are in docs/resources.md.
##
## This suite covers the FRONT of the pipeline: the `resources:` declaration,
## the `[resource: k]` marker, and `defer`. Each is a construct the language
## simply did not have — `resources:` was TK-PA03 "does not start a
## declaration", `[io, resource: udp]` was "Unknown effect marker: resource",
## and `defer` was a host keyword Tuck reserved but never spelled.

import ../harness

proc run*(t: var T) =
  # --- the `resources:` declaration -----------------------------------------

  # The spec's own §7.4 block, verbatim. It is fenced ```tuck there rather than
  # ```tuck-rejected, so tools/doc_snippets asserts the same thing from the
  # other side: this parsing is what un-fenced it.
  t.src """
resources:
  net  [cap: 10_000, on_full: error, sweep_batch: 100]
  file [cap: 8, on_finish: flush]
  udp

fn main() -> int:
  return 0
"""
  t.okCheck "the spec's resources block declares three kinds"

  # A kind with no attributes at all: unbounded, and the default policy.
  t.src """
resources:
  udp

fn main() -> int:
  return 0
"""
  t.okCheck "a bare kind name needs no attribute bracket"

  # `resources [policy: lazy]:` — the block default (docs/resources.md §0.1).
  t.src """
resources [policy: lazy]:
  net
  file [policy: strict]

fn main() -> int:
  return 0
"""
  t.okCheck "the block carries a default policy a kind may override"

  t.src """
resources [policy: eventually]:
  udp

fn main() -> int:
  return 0
"""
  t.badCheck "an unknown block policy names the three legal ones",
             "strict, lazy or exit"

  t.src """
resources:
  udp [policy: whenever]

fn main() -> int:
  return 0
"""
  t.badCheck "an unknown kind policy does too", "strict, lazy or exit"

  t.src """
resources:
  udp [timeout: 30]

fn main() -> int:
  return 0
"""
  t.badCheck "an unknown kind attribute lists the ones a kind takes",
             "cap, policy, on_full, on_finish and sweep_batch"

  # The block bracket is the DEFAULT, not a per-kind knob — saying `cap` there
  # would silently apply to nothing, so it is refused with the reason.
  t.src """
resources [cap: 8]:
  udp

fn main() -> int:
  return 0
"""
  t.badCheck "the block bracket takes only a policy", "per-kind attribute"

  t.src """
resources:
  udp [cap: eight]

fn main() -> int:
  return 0
"""
  t.badCheck "a non-numeric cap is rejected", "whole number"

  # `resources` is CONTEXTUAL, gated on `:` or `[` like every other opener in
  # parser.contextualDecl. A variable of that name must still read as one.
  t.src """
fn main() -> int:
  let resources = 3
  return resources
"""
  t.okCheck "a variable named 'resources' is still a variable"

  # --- the `[resource: k]` marker -------------------------------------------

  t.src """
resources:
  udp

extern:
  fn openUdp({port: u16}) -> int [io, resource: udp]

fn main() -> int:
  return 0
"""
  t.okCheck "an acquire site marks its kind in the effects bracket"

  # The marker rides in the bracket beside the valueless effect markers, and
  # `resource:` was previously "Unknown effect marker: resource" — the parse
  # error issue #32 reports as the second half of the missing feature.
  t.src """
resources:
  udp

fn open({port: u16}) -> int [io, resource: udp]:
  return 0

fn main() -> int:
  return 0
"""
  t.okCheck "a plain fn may carry the marker too, not just an extern"

  # --- `defer` ---------------------------------------------------------------

  t.src """
fn work({n: int}) -> int:
  var total = 0
  defer:
    total = 0
  total = n + 1
  return total

fn main() -> int:
  return {n: 16} work
"""
  t.okCheck "a defer block checks"
  t.emits "Nim spells it `defer:`", "defer:"
  t.emitsOdin "Odin spells it `defer {`", "defer {"
  t.emitsD "D spells it `scope(exit)`", r"scope\(exit\)"
  # The defer runs AFTER the return value is evaluated, so zeroing `total`
  # there does not change what comes back. That is the whole point of the
  # construct, and it is the same in all three targets — which is why they
  # each get their own native defer rather than a lowering.
  t.runs "...and the deferred write lands after the value is taken", 17

  # A defer must not be silently mis-indented into the statement before it.
  t.src """
fn main() -> int:
  var n = 1
  defer:
    n = 0
  if n == 1:
    n = 17
  return n
"""
  t.runs "a defer beside an if keeps its own layout", 17

  t.src """
fn main() -> int:
  defer: discard
  return 0
"""
  t.badCheck "a one-line defer is refused, with the reason",
             "indented block"

  # `defer` is contextual for the same reason `resources` is.
  t.src """
fn main() -> int:
  let defer = 3
  return defer
"""
  t.okCheck "a variable named 'defer' is still a variable"

  # --- digit separators -----------------------------------------------------
  #
  # `cap: 10_000` is how §7.4 writes the number, so the lexer had to learn the
  # separator before the spec's own block could parse. Not resource-specific
  # once it exists, which is why it is tested as its own thing.

  t.src """
fn main() -> int:
  return 10_017 - 10_000
"""
  t.runs "a digit separator is a readability mark, not a digit", 17

  t.src """
fn main() -> int:
  let mask = 0xFF_FF
  return mask - 65_518
"""
  t.runs "...in hex too", 17

  t.src """
fn main() -> int:
  let x = 1__0
  return x
"""
  t.badCheck "a doubled separator is a typo, not a number", "between digits"

  t.src """
fn main() -> int:
  let x = 10_
  return x
"""
  t.badCheck "a trailing separator is too", "between digits"
