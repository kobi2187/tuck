## `with` — the record UPDATE, and the shortcut it exists for.
##
## Tuck is value-semantic: TK-TY15 refuses `..` on a parameter, so a fn that
## "mutates" its receiver had to spell the dance by hand —
##
##   fn complete({self: Task}) -> Task:
##     var s = self
##     s ..done {true}
##     return s
##
## `self with {done: true}` is that, as one expression. The property that
## makes it work is TYPE PRESERVATION: `with` returns the receiver's own type,
## so the result satisfies `-> Task`. `bake` deliberately does not — it is
## partial application and may GROW the shape — which is why bake could not
## be the shortcut even though it shares the emission.
##
## The type-preservation rule has a codegen half that `tuck ch` cannot see:
## a named record must rebuild through its own constructor. Emitting bake's
## anonymous tuple typechecked clean and then failed the Nim compile with
## `got tuple[...] but expected tuck_Task = object` — hence the run assertions.

import ../harness

const Task = """
type Task:
  title: str
  done: bool
  score: int
"""

proc run*(t: var T) =
  t.src Task & """
fn complete({self: Task}) -> Task:
  return self with {done: true}

fn main() -> int:
  let a = {title: "x", done: false, score: 1} Task
  let b = a.complete
  if b.done and b.title == "x" and b.score == 1:
    return 0
  return 1
"""
  t.okCheck "`with` in return position satisfies the receiver's own type"
  t.runs "the untouched fields carry over, the named one is replaced", 0

  # The receiver is NOT modified — the whole point of value semantics is that
  # the caller's binding is untouched.
  t.src Task & """
fn complete({self: Task}) -> Task:
  return self with {done: true}

fn main() -> int:
  let a = {title: "x", done: false, score: 1} Task
  let b = a.complete
  if a.done:
    return 1
  if not b.done:
    return 2
  return 0
"""
  t.runs "the receiver is unchanged; `with` returns a copy", 0

  # Several fields at once, and an expression (not just a literal) as a value.
  t.src Task & """
fn bump({self: Task, n: int}) -> Task:
  return self with {score: self.score + n, title: "bumped"}

fn main() -> int:
  let a = {title: "x", done: false, score: 1} Task
  let b = {self: a, n: 4} bump
  if b.score == 5 and b.title == "bumped" and not b.done:
    return 0
  return 1
"""
  t.runs "several fields, and a value computed from the receiver", 0

  # A named record must rebuild through its own constructor. This is the
  # assertion that fails if the emission ever reverts to bake's bare tuple.
  t.hostBuilds "every backend's host compiler accepts a `with` on a record"
  t.emits "a named record rebuilds through its constructor, not a tuple",
          "tuck_Task\\(title: .bumped., done: self\\.done"
  t.emitsOdin "...and Odin uses its own struct literal",
              r"tuck_Task\{title = "

  # A field the record has not got. `bake` would ADD it and silently change
  # the type; `with` refuses, because a grown shape is no longer a Task.
  t.src Task & """
fn main() -> int:
  let a = {title: "x", done: false, score: 1} Task
  let b = a with {dnoe: true}
  return 0
"""
  t.badCheck "a misspelled field is rejected, not added", "TK-TY21"
  t.badCheck "...and the message names the type and the field", "'Task' has no field 'dnoe'"

  # A field that exists but is given the wrong type.
  t.src Task & """
fn main() -> int:
  let a = {title: "x", done: false, score: 1} Task
  let b = a with {score: "seven"}
  return 0
"""
  t.badCheck "a wrong-typed value is rejected", "expects int"

  # `with` is a SOFT keyword: only `with {` makes it the combinator, so the
  # word is still available as an ordinary name.
  t.src """
fn main() -> int:
  let with = 3
  return with - 3
"""
  t.okCheck "`with` is still usable as a plain name"

  # A const may hold a combinator: it is a pure compile-time rewrite of its
  # operands. This went unguarded while the combinators were calls with a
  # magic callee name (constCheckCallee allow-listed the four strings), and
  # promoting them to exkCombinator nodes silently broke it — constCheck's
  # `else` rejected the new kind, and no test noticed.
  t.src """
const BASE = {a: 1, b: 2}
const FIXED = BASE bake {b: 9}
const UPDATED = BASE with {a: 4}

fn main() -> int:
  return FIXED.b - UPDATED.a - 5
"""
  t.okCheck "a const may hold a combinator"
  t.runs "...and it evaluates at compile time", 0

  # The bug class hostBuilds exists for. A record constructed with a field
  # left unset carries `<uninit>[T]`, which the checker is happy with and
  # which two of the three backends could not emit — Odin printed
  # `op: <uninit>(tuck_BinOp)` and D refused the type application outright.
  # okCheck and emits are both blind to it; only a host compile is not.
  t.src """
type Slot:
  a: int
  fill: int

fn main() -> int:
  let s = {a: 1} Slot
  let done = s with {fill: 41}
  return done.a + done.fill - 42
"""
  t.okCheck "a record with an unset field checks clean"
  t.hostBuilds "...and every backend can actually emit it"
  t.runs "...and it runs", 0

  # All four combinators through the one shape module, on all three backends.
  # Twelve near-identical procs became three adapters over record_shape.nim;
  # this is the assertion that says the adapters agree.
  t.src """
type Point:
  x: int
  y: int

type Label:
  tag: str

fn main() -> int:
  let p = {x: 1, y: 2} Point
  let l = {tag: "here"} Label
  let moved = p with {y: 9}
  let named = p alias(x: across, y: down)
  let both = {a: p, b: l} merge
  let fixed = p bake {x: 5}
  return moved.y + named.across + both.x + fixed.x - 16
"""
  t.okCheck "with / alias / merge / bake in one program"
  t.hostBuilds "...and all three backends emit code their host compiler takes"

  t.finish()
