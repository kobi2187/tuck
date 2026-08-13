## Every gated example must compile through tuck; the rest may fail.
##
## WHAT AN EXAMPLE CLAIMS, AND WHY COMPILE-ONLY IS OFTEN THE RIGHT GATE.
## `examples/` holds two kinds of file doing two different jobs, and the
## difference is visible in the source rather than in a list here:
##
##   NO `fn main`   — a SYNTAX SPECIMEN. It claims only "this is how the
##                    construct is written". There is nothing to run, and
##                    compiling IS the whole assertion. 15 files today
##                    (10-invariants, 19-event-registry, ...). Many describe
##                    features whose MEANING the compiler cannot execute yet;
##                    the specimen pins the surface while the semantics grow.
##
##   `fn main`      — a PROGRAM. It claims "this runs", and a `-> int` main
##                    additionally claims "and computes THIS". Those claims
##                    need a run, which is why 14 of them carry an expected
##                    exit code in tests/suites/odin_backend.nim's `odinRun`
##                    and more run through cli_smoke.
##
## So a compile-only gate is not weak gating of a program, it is correct
## gating of a specimen. What it CANNOT catch is a specimen whose meaning
## quietly went wrong: 19-event-registry declared an event it never handled,
## and 20 raised three and handled none, both compiling happily for months.
## That is not a missing run — a run would not have caught it either. It is a
## missing RULE, and the fix was to write one (spec Part 10, TK-RG03), after
## which both files failed to compile and were corrected.
##
## The lesson worth keeping: for a specimen, the checker is the only reader.
## When a specimen goes stale it is because a rule is unenforced, so the fix
## belongs in the checker, not in this suite's gating.
##
## Replaces tests/compile_all_examples.nim. That one ran the pipeline in-process
## (linking parser + typecheck + codegen into a Nim program), then re-verified
## the emitted Nim with ~25 serial `nim check` calls. Both are gone: `tuck c`
## does the same compile, and the emitted code is gated end-to-end by
## tests/odin_backend.nim and tests/cli_smoke.sh, which COMPILE AND RUN it.
##
## Gated = must compile. Ungated examples reference deliberately-undeclared
## sketch functions (fetch, merge, ...) and are allowed to fail; they are still
## built here so a crash is visible, just not fatal. Move a name into the gated
## list when it goes green.

import std/[os, algorithm, strutils]
import ../harness

const gated = """
01-data-flow 02-builder-mutation 03-functions-bake 04-sum-types-interface
05-actors-effects 06-transitions-example 07-comments 08-actors_isolated_state
09-decision-table 10-invariants 11-embedded-feature
12-transition-the-ctor-exception 13-arena-mem 14-task 15-type-attributes
17-input-merge 18-alias 19-event-registry 20-embedded-mp3-player
21-decision-bitmask 22-error-policy
23-units 24-stdlib 25-pools 26-actor-run 27-actor-select 28-async-task
29-task-timeout 30-async-read 31-fnsig-callback 32-duration-units
33-ffi-zlib 34-ffi-cstring 35-ffi-struct 36-ffi-enum-callback
38-division 39-if-match-expr 40-saturating 41-tostr-concat 42-net-echo
43-literal-payload
http
"""

# NOT gated, and why:
#   16-actor-tasks-unified-syntax — genuinely broken: dotted select sources
#     (`resp.ok`, `timeout.5s`) parse as opaque strings. See MISSING-FEATURES.
#   37-ffi-handle — compiles only with the examples dir as --root, because its
#     `lib: "cffi/point.c"` is relative to that. It IS compile- and run-gated
#     in odin_backend.sh, which sets that up.
#
# Everything else above was ungated purely by drift: 15 examples compiled fine
# and nothing here would have noticed them breaking. Several were run-gated in
# odin_backend.sh while invisible to this file, so a Nim-side regression was
# silent. Add a name here the moment it goes green.

proc run*(t: var T) =
  let gatedSet = gated.split()

  var files: seq[string]
  for f in walkFiles("examples/*.tuck"): files.add f
  sort(files)

  var idx: seq[(string, int)]
  for f in files:
    let name = f.extractFilename.changeFileExt("")
    idx.add (name, t.needCmd(@["./tuck", "c", f, "-o:" & (t.dir / name),
                               "--root:" & t.root]))

  if t.phase == pReport:
    for (name, i) in idx:
      let (rc, outp) = t.resultOf(i)
      let last = if outp.strip.len == 0: "" else: outp.strip(leading = false).splitLines()[^1]
      let isGated = name in gatedSet
      if rc == 0:
        if isGated: t.ok "compile " & name
      elif isGated:
        t.no "compile " & name, "gated regression: " & last
      else:
        echo "  skip  " & name & " (not gated) — " & last

  t.finish()
