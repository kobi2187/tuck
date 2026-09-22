# compiler/verbose.nim
#
# `-v` / `-vv` — the pipeline's own running commentary.
#
# Its own module because more than one place needs to time a stage. It lived
# in `tuck.nim` while the driver was the only caller; the moment a pass moved
# into a module of its own (`backend_prepare`), that pass needed to time its
# per-module sub-steps too, and the choice was to pass timing hooks through as
# callbacks or to let both import the facility. A facility is not a pass, so
# it is this.
#
# LEVELS:
#   -v    every named pipeline stage, with its total
#   -vv   ...and each stage's per-module sub-steps, each timed on its own
#
# Off by default. This is diagnostic output, not something every check,
# compile or build should print, and it goes to STDERR so that `tuck c`'s
# emitted source stays pipeable.
import times, strutils
import pipeline

var verboseLevel* = 0
  ## Set once from the command line. A module-level var rather than a
  ## parameter threaded through every stage: it is read-only after argument
  ## parsing and nothing in the compiler branches on it except to print.

proc elapsedMs*(t0: float): string =
  formatFloat((epochTime() - t0) * 1000.0, ffDecimal, 1) & " ms"

proc vBegin*(stage: PipelineStage): float =
  ## Announce a stage and hand back the clock to close it with.
  if verboseLevel >= 1: stderr.writeLine "-- " & $stage & " starting"
  epochTime()

proc vEnd*(stage: PipelineStage, t0: float) =
  if verboseLevel >= 1:
    stderr.writeLine "-- " & $stage & " done (" & elapsedMs(t0) & ")"

proc vSub*(name: string, t0: float) =
  ## One module's share of the stage now running.
  if verboseLevel >= 2:
    stderr.writeLine "     " & name & " (" & elapsedMs(t0) & ")"

proc vSubNote*(msg: string) =
  ## Like `vSub`, but for a sub-step with no individual timing worth showing —
  ## the underlying call has no per-item hook to time separately.
  if verboseLevel >= 2: stderr.writeLine "     " & msg
