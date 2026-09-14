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
  net  [cap: 10_000, policy: lazy, on_full: error, sweep_batch: 100]
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
             "cap, policy, on_full, on_finish, sweep_batch and states"

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

  # --- the checker: kind validation -----------------------------------------
  #
  # §7.4: "An unknown kind in `[resource: k]` is a compile error, same as an
  # undeclared error enum." Kinds are program-wide, so every rule about them
  # is checked whole-program, beside checkRegistry and checkErrCodeCollisions.

  t.src """
resources:
  udp

fn open({port: u16}) -> int [io, resource: tcp]:
  return 0

fn main() -> int:
  return 0
"""
  t.badCheck "a marker naming no declared kind is refused", "TK-RS01"

  # The knobs are properties of ONE table, so a second block claiming the kind
  # has nowhere to put its own — silently keeping the first block's cap is the
  # last-writer-wins that only surfaces as a wrong bound in production.
  t.src """
resources:
  udp [cap: 4]

resources:
  udp [cap: 99]

fn main() -> int:
  return 0
"""
  t.badCheck "one kind declared twice is refused", "TK-RS02"

  # ...but two DIFFERENT kinds in two blocks is the open set §7.4 asks for.
  t.src """
resources:
  udp

resources:
  file

fn main() -> int:
  return 0
"""
  t.okCheck "two blocks declaring different kinds is the open set"

  # --- the checker: propagation ---------------------------------------------
  #
  # §3.7, explicit not inferred — the same rule effects follow, enforced by
  # the same walk (semantics.Demands carries both).

  t.src """
resources:
  udp

extern:
  fn openUdp({port: u16}) -> int [io, resource: udp]

fn listen({port: u16}) -> int [io]:
  return {port: port} openUdp

fn main() -> int:
  return 0
"""
  t.badCheck "a caller that does not declare the kind it acquires is refused",
             "TK-RS03"

  t.src """
resources:
  udp

extern:
  fn openUdp({port: u16}) -> int [io, resource: udp]

fn listen({port: u16}) -> int [io, resource: udp]:
  return {port: port} openUdp

fn main() -> int:
  return 0
"""
  t.okCheck "...and is accepted once it declares it"

  # `main` is the program's impure entry point for resource kinds exactly as
  # it is for effects: `fn main() -> int` has nowhere natural to carry the
  # marker, and opening a socket there is the ordinary case.
  t.src """
resources:
  udp

extern:
  fn openUdp({port: u16}) -> int [io, resource: udp]

fn main() -> int:
  return {port: 0} openUdp
"""
  t.okCheck "main needs no marker, as it needs none for [io]"

  # Across a module boundary. Left out, an imported acquirer looks
  # non-acquiring to its callers and the discipline stops at the file — the
  # bug effects themselves had before SigInfo carried them.
  t.srcNamed "t.tuck", """
import net

fn relay() -> int [io]:
  return {port: 0} listen

fn main() -> int:
  return 0
"""
  t.addFile "net.tuck", """
resources:
  udp

extern:
  fn openUdp({port: u16}) -> int [io, resource: udp]

fn listen({port: u16}) -> int [io, resource: udp]:
  return {port: port} openUdp
"""
  t.badCheck "an imported acquirer still propagates to its caller", "TK-RS03"

  # A spawned TASK's kinds do not propagate, and for a stronger reason than
  # its effects: the handle never reaches this caller's scope, so there is
  # nothing here to finish. The registry closes it (§7.4 — escape into the
  # registry is always sound).
  t.src """
resources:
  udp

extern:
  fn openUdp({port: u16}) -> int [io, resource: udp]

task serve({port: u16}) -> int [io, resource: udp]:
  return {port: port} openUdp

fn start() -> int:
  discard {port: 0} serve
  return 0

fn main() -> int:
  return 0
"""
  t.okCheck "spawning a task does not propagate its kinds to the spawner"

  # --- codegen: the tables ---------------------------------------------------
  #
  # A STATIC initializer in every backend, not a start-up call: the knobs ARE
  # the declaration, and the runtime sizes a capped table on its first
  # acquire. A program that never touches a kind pays nothing for declaring
  # it, which is what a standalone target needs.

  t.src """
resources [policy: lazy]:
  net  [cap: 10_000, on_full: error, sweep_batch: 100]
  file [cap: 8, on_finish: flush, policy: strict]
  udp

fn work({n: int}) -> int:
  var total = n
  defer:
    total = 0
  return total + 1

fn main() -> int:
  return {n: 16} work
"""
  t.okCheck "a program declaring three kinds checks"
  t.emits "Nim: the capped kind carries its cap and its own policy",
          "tuckRes_file\\* = ResourceTable\\(kind: \"file\", cap: 8, policy: rtStrict"
  t.emits "Nim: the uncapped kind is cap 0 and takes the block default",
          "tuckRes_udp\\* = ResourceTable\\(kind: \"udp\", cap: 0, policy: rtLazy"
  t.emits "Nim: the sweep batch reaches the table", "sweepBatch: 100"
  t.emitsOdin "Odin: the same table, package-level",
              "tuckRes_file: rt.ResourceTable = \\{kind = \"file\", cap = 8, policy = .Strict"
  t.emitsD "D: __gshared, because a registry is the PROCESS's handle table",
           "__gshared rt.ResourceTable tuckRes_file = \\{kind: \"file\", cap: 8"

  # Each kind's handle type is its own, so finishing a file handle into the
  # socket registry is a type error — the rule a pool's handle already
  # follows. The alias is emitted rather than resolved away: it costs one
  # line and makes the emitted signature say what it holds.
  t.emits "Nim: each kind emits its handle alias", "type FileHandle\\* = ResourceHandle"
  t.emitsOdin "Odin: likewise", "FileHandle :: rt.ResourceHandle"
  t.emitsD "D: likewise", "alias FileHandle = rt.ResourceHandle;"
  t.runs "...and the program still builds and runs on every backend", 17

  # The handle type is real in the CHECKER too, which is what lets an extern
  # binding name it as a return type.
  t.src """
resources:
  udp

extern:
  fn openUdp({port: u16}) -> UdpHandle [io, resource: udp]

fn main() -> int:
  return 0
"""
  t.okCheck "a kind's handle type is usable in a signature"

  # Nominal, not structural: two empty records would otherwise match, and
  # handing a file handle to something expecting a socket would check clean.
  t.src """
resources:
  udp
  file

fn take({h: UdpHandle}) -> int:
  return 0

fn give({h: FileHandle}) -> int:
  return {h: h} take

fn main() -> int:
  return 0
"""
  t.badCheck "two kinds' handles are not interchangeable", "UdpHandle|FileHandle"

  # --- codegen: the shutdown -------------------------------------------------
  #
  # §7.4's close-all, plus the OPEN RESOURCES report that runs just before it.
  # In the ENTRY POINT in all three backends rather than an at-exit hook: Odin
  # cannot use one at all (its entry ends in os.exit, which is `_exit` and runs
  # no finalizer, so an @(fini) proc never fires — checked, not assumed), and
  # the entry point already owns the lifecycle at the other end, where it boots
  # the scheduler.

  t.src """
resources:
  net
  file

fn main() -> int:
  return 0
"""
  t.emits "Nim: one shutdown proc per program", "proc tuckResourcesShutdown\\*\\(\\)"
  # Reverse DECLARATION order across kinds — the same LIFO reading the
  # within-table order follows. A kind declared later is likelier to sit on
  # top of an earlier one (a TLS session over its socket).
  t.emits "Nim: ...closing the kinds in reverse declaration order",
          "shutdownResources\\(tuckRes_file\\)\\n  shutdownResources\\(tuckRes_net\\)"
  t.emitsOdin "Odin: the same proc", "tuckResourcesShutdown :: proc\\(\\)"
  t.emitsD "D: the same proc", "void tuckResourcesShutdown\\(\\)"
  t.runs "...and a program declaring kinds still runs and returns its code", 0

  # A program with no `resources:` block emits no table, no shutdown proc and
  # no call to one — declaring nothing costs nothing.
  t.src """
fn main() -> int:
  return 0
"""
  t.omits "Nim: no kinds, no shutdown", "tuckResourcesShutdown"
  t.omitsOdin "Odin: likewise", "tuckResourcesShutdown"
  t.omitsD "D: likewise", "tuckResourcesShutdown"

  # --- on_full and on_finish ------------------------------------------------
  #
  # Both are CLOSED vocabularies, and both reach the emitted table. They used
  # to parse into the AST and get dropped at codegen — five attributes
  # declared, three acted on, and nothing saying so.

  t.src """
resources [policy: lazy]:
  net  [cap: 4, on_full: error]
  file [cap: 8, on_finish: flush, policy: strict]
  sock [cap: 2, on_finish: shutdown]
  udp

fn main() -> int:
  return 0
"""
  t.okCheck "on_full and on_finish check"
  t.emits "Nim: on_full reaches the table", "kind: \"net\".*onFull: rtoError"
  t.emits "Nim: a kind that does not name one gets the default",
          "kind: \"udp\".*onFull: rtoAbsent"
  # ONE mechanism: the declaration PICKS the runtime callback rather than
  # setting a flag the runtime switches on, so `setResourceHooks` overriding
  # it writes the same field and the two cannot disagree.
  t.emits "Nim: on_finish binds the runtime proc", "onFinish: tuckResFlush"
  t.emits "Nim: ...and shutdown binds the other one", "onFinish: tuckResShutdown"
  t.omits "Nim: a kind with no on_finish binds nothing at all",
          "kind: \"udp\".*onFinish"
  t.emitsOdin "Odin: the same two fields",
              "kind = \"file\".*onFull = .Absent.*onFinish = rt.tuckResFlush"
  t.emitsD "D: likewise",
           "kind: \"file\".*onFull: rt.RtOnFull.Absent.*onFinish: &rt.tuckResFlush"
  t.runs "...and a program declaring all of them still runs", 0

  t.src """
resources:
  udp [cap: 4, on_full: retry]

fn main() -> int:
  return 0
"""
  t.badCheck "an unknown on_full names the legal ones", "absent or error"

  t.src """
resources:
  udp [on_finish: sync]

fn main() -> int:
  return 0
"""
  t.badCheck "an unknown on_finish does too", "none, flush or shutdown"

  # An unbounded table never fills, so `on_full` on one could never apply.
  # Checked after the whole bracket, since `cap` may be written after it.
  t.src """
resources:
  udp [on_full: error]

fn main() -> int:
  return 0
"""
  t.badCheck "on_full without a cap is refused, with the reason",
             "on_full needs a cap"

  # A kind's knobs CONSTRAIN EACH OTHER — the combination is the declaration,
  # not the individual words — so a pair that can never mean anything together
  # is named rather than left to quietly do nothing.
  t.src """
resources:
  net [cap: 10_000, on_full: error, sweep_batch: 100]

fn main() -> int:
  return 0
"""
  t.badCheck "sweep_batch outside `lazy` is refused: no other policy sweeps",
             "sweep_batch needs `policy: lazy`"

  t.src """
resources [policy: lazy]:
  net [cap: 10_000, on_full: error, sweep_batch: 100]

fn main() -> int:
  return 0
"""
  t.okCheck "...and the block default satisfies it, not just a per-kind policy"

  # The line is PERMANENTLY incoherent vs merely inert today, and only the
  # first gets a rule. `policy: lazy` without a cap never trips the watermark
  # in this implementation — but §7.4 names two other triggers for the same
  # sweep ("on memory pressure, or at cap"), and memory pressure needs no cap.
  # A trigger not yet built is a different thing from a combination that could
  # never work.
  t.src """
resources:
  udp [policy: lazy]

fn main() -> int:
  return 0
"""
  t.okCheck "lazy without a cap is inert today, not incoherent — so allowed"

  # --- `finish <handle>, <kind>` ---------------------------------------------
  #
  # §7.4's release INTENT. The kind is named even though the handle's TYPE
  # already decides the table, and that redundancy is the feature: a release
  # is read far more often than written, and the reader should not have to
  # find the declaration of `sock` to learn which registry is touched. The
  # checker verifies the two agree, so the second source of truth cannot
  # drift from the first.

  t.src """
resources:
  udp
  file [cap: 8, on_finish: flush, policy: strict]

pending:
  fn openUdp({port: u16}) -> UdpHandle [io, resource: udp]

fn serve({port: u16}) -> int [io, resource: udp]:
  let sock = {port: port} openUdp
  defer:
    finish sock, udp
  return 0

fn main() -> int:
  return 0
"""
  t.okCheck "a finish inside a defer checks"
  # The kind names the table directly, so the redundancy the source spells out
  # costs nothing at runtime — no dispatch, no table id on the handle.
  t.emits "Nim: the kind resolves to its table at compile time",
          "finish\\(tuckRes_udp, tuck_sock\\)"
  t.emitsOdin "Odin: likewise, by pointer",
              "rt.finishResource\\(&tuckRes_udp, tuck_sock\\)"
  t.emitsD "D: likewise, by ref",
           "rt.finishResource\\(tuckRes_udp, tuck_sock\\)"
  # Built, not run: the handle comes from a `pending:` stub, so there is no
  # real registry entry behind it and a run would (correctly) abort on the
  # stale-handle check. What matters here is that the emitted call LINKS.
  t.builds "...and the emitted call compiles and links"

  # THE point of the explicit form: a handle finished into the wrong registry
  # is caught, by name, at compile time.
  t.src """
resources:
  udp
  file [cap: 8]

pending:
  fn openUdp({port: u16}) -> UdpHandle [io, resource: udp]

fn serve({port: u16}) -> int [io, resource: udp]:
  let sock = {port: port} openUdp
  finish sock, file
  return 0

fn main() -> int:
  return 0
"""
  t.badCheck "finishing into the wrong registry is TK-RS04", "TK-RS04"

  # The kind must be DECLARED, the same rule the marker follows. Asked by the
  # whole-program pass rather than the module checker, because a module may
  # finish into a kind that a module it imports declared.
  t.src """
resources:
  udp

fn main() -> int:
  let h = {} UdpHandle
  finish h, tcp
  return 0
"""
  t.badCheck "finishing into an undeclared kind is TK-RS01", "TK-RS01"

  t.src """
resources:
  udp

fn main() -> int:
  let h = {} UdpHandle
  finish h
  return 0
"""
  t.badCheck "omitting the kind is refused, showing the form",
             "finish <handle>, <kind>"

  # `finish` is contextual, gated on a NAME following: Tuck calls are postfix,
  # so two bare identifiers in a row are not an expression in any other
  # construct — while an ordinary name spelled `finish` still reads as one.
  t.src """
fn main() -> int:
  let finish = 17
  return finish
"""
  t.runs "a variable named 'finish' is still a variable", 17

  # --- `acquire <raw>, <kind>` -----------------------------------------------
  #
  # The mirror of `finish`, and one parser builds both: same keyword position,
  # same operand order, same trailing kind name. Acquire takes a RAW number in
  # and yields `?<Kind>Handle`; finish takes a typed handle and yields nothing.
  # The pair is what keeps the raw fd out of Tuck entirely — it exists between
  # the extern's return and the acquire, and nowhere else.

  t.src """
resources:
  slot [cap: 2]

fn take({fd: int}) -> ?SlotHandle [resource: slot]:
  return acquire fd, slot

fn main() -> int:
  var n = 0
  let a = {fd: 10} take
  if a.ok:
    n = n + 1
    let b = {fd: 11} take
    if b.ok:
      n = n + 2
      let c = {fd: 12} take
      if c.ok:
        n = n + 100
      finish a.value, slot
      let d = {fd: 13} take
      if d.ok:
        n = n + 14
  return n
"""
  t.okCheck "acquire and finish check together"
  # The acquire SITE is supplied by the compiler from the span — the author
  # never writes it, and a site an author had to supply is one that goes stale
  # the first time a line moves.
  t.emits "Nim: the kind resolves to its table, with the site attached",
          "acquire\\(tuckRes_slot, int64\\(fd\\), \"t:5\"\\)"
  t.emitsOdin "Odin: likewise", "rt.acquireResource\\(&tuckRes_slot, i64\\(fd\\)"
  t.emitsD "D: likewise", "rt.acquireResource\\(tuckRes_slot, cast\\(long\\)\\(fd\\)"
  # 1 + 2 + 14: the third acquire is ABSENT because the cap is 2 (not 100),
  # and the fourth succeeds only because the `finish` freed a slot. One exit
  # code pins the whole loop.
  t.runs "...and the cap, the absence and the re-acquire all hold", 17

  # `?T` is not special-cased for handles: the existing optional discipline
  # applies, so reading `.value` without a guard is the ordinary error.
  t.src """
resources:
  slot [cap: 2]

fn take({fd: int}) -> ?SlotHandle [resource: slot]:
  return acquire fd, slot

fn main() -> int:
  let a = {fd: 1} take
  finish a.value, slot
  return 0
"""
  t.badCheck "an unguarded handle is the ordinary unhandled-optional error",
             "unhandled \\?SlotHandle"

  # acquire takes the RAW handle an extern produced. Handing it something
  # already registered would put one handle in the table twice.
  t.src """
resources:
  slot [cap: 2]

fn bad({h: SlotHandle}) -> ?SlotHandle [resource: slot]:
  return acquire h, slot

fn main() -> int:
  return 0
"""
  t.badCheck "acquiring an already-registered handle is TK-RS05", "TK-RS05"

  t.src """
resources:
  slot

fn take({fd: int}) -> ?SlotHandle [resource: slot]:
  return acquire fd, disk

fn main() -> int:
  return 0
"""
  t.badCheck "acquiring into an undeclared kind is TK-RS01", "TK-RS01"

  t.src """
resources:
  slot

fn take({fd: int}) -> ?SlotHandle [resource: slot]:
  return acquire fd

fn main() -> int:
  return 0
"""
  t.badCheck "omitting the kind shows acquire's own form", "acquire <raw>, <kind>"

  t.src """
fn main() -> int:
  let acquire = 17
  return acquire
"""
  t.runs "a variable named 'acquire' is still a variable", 17

  # --- a kind's PROTOCOL ------------------------------------------------------
  #
  # A kind's protocol is a sealed sum type it NAMES, not one it restates:
  #
  #   type DbState: | Open | InTransaction | Closed  (+ transitions)
  #   resources: db [cap: 4096, states: DbState]
  #
  # The two halves have different OWNERS, which is the whole reason they are
  # decoupled. A `resources:` block is the APP's — it decides which tables
  # exist and how large they are, a deployment question no library can answer.
  # The protocol of an OS service is the LIBRARY's — it knows a connection
  # goes Open -> InTransaction -> Closed, which no app should have to restate
  # and none should be able to restate differently.
  #
  # The compiler still generates <Kind>Handle, so there is still no envelope:
  # the library writes an ordinary sum type, which is the one thing it
  # genuinely knows.

  t.src """
type DbState:
  | Open
  | Closed
  transitions:
    Open -> Closed

resources:
  file [cap: 8, on_finish: flush]
  db [cap: 32, states: DbState]

fn main() -> int:
  return 0
"""
  t.okCheck "a kind may name a protocol, and a kind beside it may not"
  # The protocol is a STATIC overlay: the emitted handle is unchanged, so a
  # kind gains states at zero runtime cost and no backend learns anything.
  t.emits "a kind with a protocol emits the same handle as one without",
          "DbHandle\\* = ResourceHandle"

  t.src """
resources:
  db [cap: 4, states: Nope]

fn main() -> int:
  return 0
"""
  t.badCheck "`states:` naming no sum type is refused", "TK-RS10"

  # A sum type with no edges says nothing about how the resource moves, so
  # naming one is a mistake rather than a protocol.
  t.src """
type DbState:
  | Open
  | Closed

resources:
  db [cap: 4, states: DbState]

fn main() -> int:
  return 0
"""
  t.badCheck "`states:` naming a sum type with no transitions is refused",
             "TK-RS10"

  t.src """
type DbState:
  | Open
  | Closed
  transitions:
    Open -> Clsoed

resources:
  db [cap: 4, states: DbState]

fn main() -> int:
  return 0
"""
  t.badCheck "a mistyped edge endpoint is refused, naming it", "TK-RS06"

  # The closing state is DERIVED (no outgoing edge), never declared, so it
  # cannot be declared wrong; what can be wrong is the edge set.
  t.src """
type DbState:
  | Open
  | InTransaction
  | Closed
  transitions:
    Open -> InTransaction
    Open -> Closed

resources:
  db [cap: 4, states: DbState]

fn main() -> int:
  return 0
"""
  t.badCheck "two states with no way out means no single closing state",
             "TK-RS07"

  # The rule that earns the feature: a live cycle with no exit is a handle
  # that cannot be closed from where it is.
  t.src """
type DbState:
  | Open
  | A
  | B
  | Closed
  transitions:
    Open -> A
    A    -> B
    B    -> A
    Open -> Closed

resources:
  db [cap: 4, states: DbState]

fn main() -> int:
  return 0
"""
  t.badCheck "a state the closing one cannot be reached from is a leak",
             "cannot be closed from where it is"

  # A kind with a protocol acquires and finishes exactly as one without — the
  # protocol adds a well-formedness check, not a new calling convention.
  t.src """
type DbState:
  | Open
  | Closed
  transitions:
    Open -> Closed

resources:
  db [cap: 4, states: DbState]

fn take({fd: int}) -> ?DbHandle [resource: db]:
  return acquire fd, db

fn main() -> int:
  let h = {fd: 3} take
  if h.ok:
    finish h.value, db
    return 17
  return 0
"""
  t.runs "a kind with a protocol still acquires, finishes and runs", 17

  # An indented block may OPEN with a comment. A comment-only line lexes as a
  # bare newline, and `indentedBlock` expected the indent immediately — so
  # every construct except a fn body (which grew its own skip) rejected one.
  t.src """
type DbState:
  # what this connection can be
  | Open
  | Closed
  transitions:
    # ...and the only way out
    Open -> Closed

resources:
  db [cap: 4, states: DbState]

fn main() -> int:
  return 0
"""
  t.okCheck "a protocol's blocks may open with a comment"

  t.src """
type Light:
  # the states a signal shows
  | Red
  | Green
  transitions:
    # green follows red, and nothing follows green
    Red -> Green
"""
  t.okCheck "so may any other indented block — the skip is in the scaffolding"

  # A kind is declared ONCE, by the library that owns it, and every app that
  # imports it uses it. That is what makes a protocol worth writing: the edges
  # are the LIBRARY's knowledge, so an app that re-stated them could state them
  # differently — and a kind declared twice is refused anyway.
  #
  # The two halves this rests on were both broken, in a way only an import
  # showed: `main`'s blanket budget was the kinds of its OWN module, so an
  # imported kind was outside it, and main's explicit `[resource: k]` was
  # discarded rather than unioned in, so the one available workaround was a
  # no-op too.
  t.srcNamed "t.tuck", """
import dblib

fn main() -> int:
  let h = {fd: 3} connect
  if h.ok:
    finish h.value, db
    return 17
  return 0
"""
  t.addFile "dblib.tuck", """
type DbState:
  | Open
  | InTransaction
  | Closed
  transitions:
    Open          -> InTransaction
    InTransaction -> Open
    Open          -> Closed
    InTransaction -> Closed

resources:
  db [cap: 32, states: DbState]

fn connect({fd: int}) -> ?DbHandle [resource: db]:
  return acquire fd, db
"""
  t.runs "a library owns the kind and its protocol; the app just imports it", 17

  # ...and the marker an author writes on main is honoured rather than ignored.
  t.srcNamed "t.tuck", """
import dblib2

fn main() -> int [resource: db2]:
  let h = {fd: 3} connect2
  if h.ok:
    finish h.value, db2
    return 17
  return 0
"""
  t.addFile "dblib2.tuck", """
resources:
  db2 [cap: 4]

fn connect2({fd: int}) -> ?Db2Handle [resource: db2]:
  return acquire fd, db2
"""
  t.runs "main may state the imported kind it uses, and be believed", 17
