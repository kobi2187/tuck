## The host-facing externs listDir (std/fs) and runCommand (std/sys). Each runs
## on every backend the harness has, so the three runtimes are held to the same
## answers. (split and parseInt live in stdlib-project: core.str.text and
## core.convert, exercised by the stdlib_project suite.)

import ../harness

proc run*(t: var T) =
  t.src """
import fs
import sys
import seq

fn main() -> int [io]:
  let names = {path: "/"} listDir
  let missing = {path: "/no/such/dir"} listDir
  let code = {line: "exit 3"} runCommand
  var r = code
  if {items: names} count > 0:
    r = r + 10
  r = r + ({items: missing} count) * 100
  return r
"""
  t.runs "listDir lists a directory, is empty for a missing one, and runCommand returns the exit code", 13

  t.finish()
