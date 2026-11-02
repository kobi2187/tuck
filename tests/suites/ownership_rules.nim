## Rule U — every read of an owning value is a borrow or a sink — as the
## classifier in compiler/ownership_rules.nim answers it.
##
## The ownership rules (thoughts/shared/plans/2026-10-05-ownership-rules-
## proposal.md, ruled 2026-10-05) all start here: S moves or copies only at a
## sink, P looks for a sink among a parameter's final reads, D drops what the
## sinks left. So what each position IS gets pinned before anything is built
## on it, read off `TUCK_DEBUG_OWN=uses`: one line per read of an owning
## place, with its use once every pass-through above it is resolved, and
## whether the SSA mirror proved it the place's final use.
##
## What a classification looks like on the wire (names as mangled):
##
##   USE tuckˑfnˑboth tuckˑvˑxs sink 18:11
##
## `arg` is a call's argument, settled by rule P from the callee — pinned
## below through `TUCK_DEBUG_OWN=params` (compiler/ownership_dump.nim).
import std/[os, strutils]
import ../harness

proc usesDump(t: var T): int =
  ## The classifier's dump for the current snippet, through the Odin prepare
  ## (the tree the elaborator will run over).
  t.needCmd(@["env", "TUCK_DEBUG_OWN=uses", "./tuck", "c",
              t.curDir / "t.tuck", "--odin", "-o:" & t.curDir / "out"], vEmit)

proc paramsDump(t: var T): int =
  ## Rule P, for the current snippet.
  t.needCmd(@["env", "TUCK_DEBUG_OWN=params", "./tuck", "c",
              t.curDir / "t.tuck", "--odin", "-o:" & t.curDir / "outp"], vEmit)

proc dropsDump(t: var T): int =
  ## Rules D and M, for the current snippet.
  t.needCmd(@["env", "TUCK_DEBUG_OWN=drops", "./tuck", "c",
              t.curDir / "t.tuck", "--odin", "-o:" & t.curDir / "outd"], vEmit)

proc copiesDump(t: var T): int =
  ## Rule S as written into the Odin tree (`exkCopy`), for the current
  ## snippet.
  t.needCmd(@["env", "TUCK_DEBUG_OWN=copies", "./tuck", "c",
              t.curDir / "t.tuck", "--odin", "-o:" & t.curDir / "outc"], vEmit)

proc verifyDump(t: var T): int =
  ## Rule V over the current snippet's Odin tree, as the rules wrote it.
  t.needCmd(@["env", "TUCK_DEBUG_OWN=verify", "./tuck", "c",
              t.curDir / "t.tuck", "--odin", "-o:" & t.curDir / "outv"], vEmit)

proc dumpLacks(t: var T, idx: int, name, needle: string) =
  ## The dump has no line holding `needle` (prefixes dropped as in dumpHas).
  if t.phase != pReport: return
  if t.skippedCmd(idx):
    t.skip name
    return
  let (rc, outp) = t.resultOf(idx)
  let plain = outp.replace("tuckˑfnˑ", "").replace("tuckˑvˑ", "")
  if rc != 0: t.no name, "the compile failed: " & outp.splitLines()[^1]
  elif needle in plain: t.no name, "did not want `" & needle & "` in:\n" & plain
  else: t.ok name

proc dumpHas(t: var T, idx: int, name, line: string) =
  ## The dump has `line` (with the `tuckˑfnˑ` / `tuckˑvˑ` prefixes dropped).
  if t.phase != pReport: return
  if t.skippedCmd(idx):
    t.skip name
    return
  let (rc, outp) = t.resultOf(idx)
  let plain = outp.replace("tuckˑfnˑ", "").replace("tuckˑvˑ", "")
  if rc == 0 and line in plain: t.ok name
  elif rc != 0: t.no name, "the compile failed: " & outp.splitLines()[^1]
  else: t.no name, "want `" & line & "` in:\n" & plain

proc classifies(t: var T, idx: int, name, line: string) =
  ## A rule U classification line.
  t.dumpHas(idx, name, "USE " & line)

proc run*(t: var T) =
  ## Registers the rule U classification, rule P, rules D/M, rule S and rule
  ## V assertions.
  t.src """
import seq

type Bag:
  items: Seq[int]
  tag: str

fn keep({b: Bag}) -> Seq[int]:
  return b.items

fn pick({c: bool, xs: Seq[int], ys: Seq[int]}) -> Seq[int]:
  let r = if c: xs else: ys
  return r

fn wrap({xs: Seq[int]}) -> Bag:
  return {items: xs, tag: "w"} Bag

fn both({xs: Seq[int]}) -> Seq[Seq[int]]:
  return [xs, xs]

fn join({s: str, t: str}) -> str:
  let u = s + t
  return u

fn which({s: str}) -> int:
  match s:
    | "a" -> return 1
    | _ -> return 2

fn main() -> int:
  let a = [1, 2]
  let b = {xs: a} wrap
  let k = {b: b} keep
  return k[0]
"""
  let d = t.usesDump()
  t.classifies d, "a returned path is ONE sink, of the path (not of `b`)",
               "keep b.items sink final 8:11"
  t.classifies d, "an if-value's branches take the binding's use: sink",
               "pick xs sink final 11:17"
  t.classifies d, "...both branches", "pick ys sink final 11:26"
  t.classifies d, "a construction field is a sink", "wrap xs sink final 15:18"
  t.classifies d, "a list element is a sink; the first of two is not final " &
                  "(rule S copies it)", "both xs sink 18:11"
  t.classifies d, "...and the second is final (rule S moves it)",
               "both xs sink final 18:15"
  t.classifies d, "a concatenation's operands are borrows (the bytes are " &
                  "copied)", "join s borrow final 21:11"
  t.classifies d, "a match subject is a borrow", "which s borrow final 25:9"
  t.classifies d, "an argument is `arg`, for rule P to settle",
               "main a arg final 31:16"

  # --- rule P: a parameter consumes iff some final read of it is a sink ----
  #
  # With the reason P gives. (Measured beside Nim's `sink` before the switch,
  # over every .tuck in the tree: 213 owning parameters agreed and 17
  # differed, all of one kind — `bytesOf` below: a final read handed to a
  # runtime extern that only reads it, which `sink` takes to keep anything
  # it cannot see into.)
  t.src """
import seq
import str

pending:
  fn opaque({text: str}) -> str

fn keepIt({xs: Seq[int]}) -> Seq[int]:
  return xs

fn lenOf({xs: Seq[int]}) -> int:
  return xs.len

fn bytesOf({t: str}) -> int:
  return {t: t} byteCount

fn viaKeep({xs: Seq[int]}) -> Seq[int]:
  return {xs: xs} keepIt

fn viaOpaque({t: str}) -> str:
  return {text: t} opaque

fn grow({xs: Seq[int]}) -> Seq[int]:
  return {items: xs, value: 1} push

fn walk({xs: Seq[int], n: int}) -> int:
  if n == 0:
    return xs.len
  return {xs: xs, n: n - 1} walk

fn main() -> int:
  return 0
"""
  let p = t.paramsDump()
  t.dumpHas p, "P: a parameter returned is consumed (a sink)",
            "PARAM keepIt xs consumes (a sink at 8:10)"
  t.dumpHas p, "P: one only measured is borrowed", "PARAM lenOf xs borrows"
  t.dumpHas p, "P: one handed to a runtime reader is borrowed",
            "PARAM bytesOf t borrows"
  t.dumpHas p, "P: one handed to a consuming parameter is consumed",
            "PARAM viaKeep xs consumes (keepIt keeps it at 17:15)"
  t.dumpHas p, "P: a `pending:` fn with no body is read by its " &
               "declaration: it keeps nothing it does not name, so it only " &
               "reads it", "PARAM viaOpaque t borrows"
  t.dumpHas p, "P: a callee with no body keeps only what it declares: " &
               "push says `[keeps: value]`, so it only reads its items",
            "PARAM grow xs borrows"
  t.dumpHas p, "P: a recursive reader borrows (the least fixed point)",
            "PARAM walk xs borrows"

  # --- rules D and M: where each owned place is dropped --------------------
  #
  # (Measured beside the old ownership pass before the switch, over every
  # .tuck in the tree on Odin: 343 owned slots agreed, 27 were freed only by
  # the old pass and 52 only by the rules, every one explained; the one real
  # bug among them, a pushed element freed while held, was A40.)
  t.src """
import seq

fn keep({xs: Seq[int]}) -> Seq[int]:
  return xs

fn pick({c: bool}) -> Seq[int]:
  let a = [1, 2]
  let b = [3]
  let n = [4, 5, 6]
  if c:
    return {xs: a} keep
  return {items: b, value: n.len} push

fn main() -> int:
  let r = {c: true} pick
  return r.len
"""
  let dd = t.dropsDump()
  t.dumpHas dd, "D: a consuming parameter returned is moved: nobody drops it",
            "DROP keep xs - moved"
  t.dumpHas dd, "D: an owned local nothing moves is dropped at its scope's end",
            "DROP main r - owned"
  t.dumpHas dd, "M: moved on one path and kept on the other is `maybe`: " &
                "dropped, and reset where moved",
            "DROP pick a - maybe"
  t.dumpHas dd, "D: a local only measured is dropped",
            "DROP pick n - owned"

  # --- rule S: a sink moves at an owned place's final use, else copies -----
  #
  # A temporary is the binder's (any aliasing is copied inside the callee),
  # and a dead value moves. What the copy is, is rule G's: `seq` for a Seq
  # of plain values.
  t.src """
import seq

fn take({xs: Seq[int]}) -> Seq[int]:
  var out = xs
  out = {items: out, value: 3} push
  return out

fn main() -> int:
  var a = [1, 2]
  let b = a
  var nested = [[1], [2]]
  let inner = nested[0]
  a = {items: a, value: 5} push
  nested = {items: nested, value: [9]} push
  let t = {xs: b} take
  return a.len + inner.len + t.len + nested.len
"""
  let cd = t.copiesDump()
  t.dumpHas cd, "S: a place still read later is copied where it is bound",
            "COPY main 10:11 seq"
  t.dumpHas cd, "S: an element read is copied (it is never moved out of " &
                "its container)", "COPY main 12:21 seq"

  # --- rule V: the tree checked ----------------------------------------------
  #
  # compiler/ownership_check.nim reads the Odin tree as the rules wrote it
  # (copies, drops, resets, `dropsOld`). Before the switch, over every .tuck
  # in the tree, it reported on the old passes' tree 11 places and 25
  # temporaries never dropped (A41-A45, each confirmed by TUCK_TRACK), 3
  # borrowed values returned for the caller to copy, and one list holding
  # live Seqs uncopied. The program below holds one of each; on the rules'
  # tree it reports none of them.
  t.src """
import seq

type Bag:
  items: Seq[int]

type Box[T]:
  items: Seq[T]

fn shrink({items: Seq[int]}) -> Seq[int]:
  var out: Seq[int] = []
  for x in items:
    if x > 1:
      out = {items: out, value: x} push
  return out

fn boxed[T]({xs: Seq[T]}) -> Box[T]:
  return {items: xs} Box

fn itemsOf({b: Bag}) -> Seq[int]:
  return b.items

fn early({n: int}) -> int:
  let xs = [1, 2, 3]
  if n > 5:
    return 1
  let ys = {items: xs} shrink
  return ys.len

fn refill() -> int:
  var b = {items: [1]} Bag
  b.items = [2, 3]
  return b.items.len

fn nest() -> int:
  let a = [1]
  let b = [2]
  let both = [a, b]
  return both.len + a.len

fn sumList() -> int:
  var n = 0
  for r in [1, 2]:
    n = n + r
  return n

fn main() -> int:
  let b = {items: [4, 5]} Bag
  let got = {b: b} itemsOf
  let bx = {xs: [6]} boxed
  return {n: 1} early + {} refill + {} nest + {} sumList + got.len + bx.items.len
"""
  let vd = t.verifyDump()
  t.dumpLacks vd, "V: the tree the rules write has none of these: every " &
                  "place dropped or moved once, every live read copied, " &
                  "every temporary named and dropped", "VERIFY"
  let gu = t.usesDump()
  t.classifies gu, "U: a generic record's construction takes its fields " &
                   "(`{items: xs} Box` is typed `Box[T]`)", "boxed xs sink final 17:18"
