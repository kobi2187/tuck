## `on select` in a TASK — spec §9.3's race, and what a task's await costs.
##
## Nothing covered this. `examples/29-task-timeout` is compile-gated and
## run-gated on its exit code, and its two arms return 1 and 2 — which are also
## their positions, so the example passes whether the arm's VALUE or its index
## comes back. The assertions here use 7 and 90 for exactly that reason: a
## number that cannot be confused with an arm index.
##
## The source is `openSource {ms}` (compiler/tuck_async.nim): it opens a pipe,
## arms a writer coroutine to feed one byte after `ms`, and returns the read fd
## immediately. So the delay is a real async event, not a blocking call in the
## caller.

import ../harness

proc run*(t: var T) =
  # The winning arm's VALUE comes back, not its index. Timeout wins here: a
  # 5ms deadline against a 3s source.
  t.src """
import time

extern:
  fn openSource({ms: int}) -> {fd: int} [io]

task race({fd: int}) -> {code: int} [io]:
  on select:
    | read fd        -> {}: return {code: 70}
    | timeout {5.ms} -> {}: return {code: 90}

fn main() -> int [io]:
  let slow = {ms: 500} openSource
  let r = {fd: slow.fd} race
  return r.code
"""
  t.hostRuns "the winning timeout arm's value is returned, not its index", 90

  # ...and the other way: the read wins a 900ms deadline, and 7 is neither
  # arm's position.
  t.src """
import time

extern:
  fn openSource({ms: int}) -> {fd: int} [io]

task race({fd: int}) -> {code: int} [io]:
  on select:
    | read fd          -> {}: return {code: 7}
    | timeout {900.ms} -> {}: return {code: 3}

fn main() -> int [io]:
  let fast = {ms: 10} openSource
  let r = {fd: fast.fd} race
  return r.code
"""
  t.hostRuns "the winning read arm's value is returned too", 7

  # A select with ONE arm loses the arm's return value — the task answers with
  # a zero-valued record instead of `{code: 7}`. Two arms are fine, which is
  # why every example has two.
  t.src """
extern:
  fn openSource({ms: int}) -> {fd: int} [io]

task readOne({fd: int}) -> {code: int} [io]:
  on select:
    | read fd -> {}: return {code: 7}

fn main() -> int [io]:
  let fast = {ms: 10} openSource
  let r = {fd: fast.fd} readOne
  return r.code
"""
  t.quietly: t.runs("a one-armed select returns its arm's value", 7)
  t.bugOpen "a one-armed select returns its arm's value"

  # A TIMEOUT DOES NOT BOUND LATENCY. The right arm wins and the right value
  # comes back — but not until the losing source has completed, because
  # awaiting a task drives the scheduler until ALL work finishes rather than
  # until THIS task does. Measured: a 5ms deadline against a 500ms source
  # returns 90 after 0.50s, and against a 3s source after 3.00s, on all three
  # backends. The delay scales with the source, which is what says it is the
  # await and not a fixed cost.
  #
  # Asserted through the harness's own `timeout 10` on a run: a source far
  # longer than that means a correct implementation returns ~immediately with
  # 90, and today's is killed at 10s and reports 124. Nim only — the other two
  # behave identically and three 10s runs is not worth the clock while this
  # is open.
  t.src """
import time

extern:
  fn openSource({ms: int}) -> {fd: int} [io]

task race({fd: int}) -> {code: int} [io]:
  on select:
    | read fd        -> {}: return {code: 70}
    | timeout {5.ms} -> {}: return {code: 90}

fn main() -> int [io]:
  let slow = {ms: 30000} openSource
  let r = {fd: slow.fd} race
  return r.code
"""
  t.quietly: t.runs("a fired timeout returns without waiting for the loser", 90)
  t.bugOpen "a fired timeout returns without waiting for the loser"

  t.finish()
