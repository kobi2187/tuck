## The suite registry. Every ported test file is a module here, exporting
## `run(t: var T)`, and is named exactly as its .sh predecessor was so the
## verdict lines and the goldens under tests/golden/ keep their paths.
##
## Adding a suite: write tests/suites/<name>.nim with a `run*` proc, import it
## below, and add one row to `registry`.

import ../harness
import loop_var_type, interface_call, interface_wrap, mangle
import interfaces

type Entry = tuple[name: string, body: SuiteProc, quick: bool]

# `quick` marks the check-only suites — no `tuck build`, no `odin build`. Those
# are what tests/run --quick runs, the inner-loop gate that quick-test.sh was.
let registry: seq[Entry] = @[
  ("loop_var_type",  SuiteProc(loop_var_type.run),  false),
  ("interface_call", SuiteProc(interface_call.run), true),
  ("interface_wrap", SuiteProc(interface_wrap.run), true),
  ("mangle",         SuiteProc(mangle.run),         true),
  ("interfaces",     SuiteProc(interfaces.run),     true),
]

proc suiteBody*(name: string): SuiteProc =
  for e in registry:
    if e.name == name: return e.body
  raise newException(ValueError, "no such suite: " & name)

proc allSuites*(): seq[string] =
  for e in registry: result.add e.name

proc quickSuites*(): seq[string] =
  for e in registry:
    if e.quick: result.add e.name
