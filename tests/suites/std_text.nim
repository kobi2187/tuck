## std/text (split, parseInt, written in Tuck) and the host-facing externs
## listDir (std/fs) and runCommand (std/sys). Each runs on every backend the
## harness has, so the three runtimes are held to the same answers.

import ../harness

proc run*(t: var T) =
  t.src """
import text
import seq

fn main() -> int [io]:
  let parts = {t: "10,20,x,,-5", at: ","} split
  var n = 0
  for p in parts:
    let v = {t: p} parseInt
    if v.ok:
      n = n + (v.value ^int)
    else:
      n = n + 1000
  return n
"""
  t.runs "split cuts at every separator and parseInt reads signed digits or says no", 233

  t.src """
import text
import seq

fn main() -> int [io]:
  let a = {t: "", at: ","} split
  let b = {t: "abc", at: ""} split
  let c = {t: "a--b--", at: "--"} split
  let big = {t: "99999999999999999999"} parseInt
  let lone = {t: "-"} parseInt
  var r = {items: a} count
  r = r + ({items: b} count) * 2
  r = r + ({items: c} count) * 10
  if big.ok:
    r = r + 100
  if lone.ok:
    r = r + 50
  return r
"""
  t.runs "split edge cases (empty input, empty separator, trailing separator) and parseInt refusals", 33

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
