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
## below through `TUCK_DEBUG_OWN=params`, beside today's Nim `sink`.
import std/[os, strutils]
import ../harness

proc usesDump(t: var T): int =
  ## The classifier's dump for the current snippet, through the Odin prepare
  ## (the tree the elaborator will run over).
  t.needCmd(@["env", "TUCK_OWN=legacy", "TUCK_DEBUG_OWN=uses", "./tuck", "c",
              t.curDir / "t.tuck", "--odin", "-o:" & t.curDir / "out"], vEmit)

proc paramsDump(t: var T): int =
  ## Rule P beside today's Nim `sink`, for the current snippet.
  t.needCmd(@["env", "TUCK_OWN=legacy", "TUCK_DEBUG_OWN=params", "./tuck", "c",
              t.curDir / "t.tuck", "-o:" & t.curDir / "outp"], vEmit)

proc dropsDump(t: var T): int =
  ## Rules D and M beside Odin's frees (the Stage C nodes), for the current
  ## snippet.
  t.needCmd(@["env", "TUCK_OWN=legacy", "TUCK_DEBUG_OWN=drops", "./tuck", "c",
              t.curDir / "t.tuck", "--odin", "-o:" & t.curDir / "outd"], vEmit)

proc copiesDump(t: var T): int =
  ## Rule S beside the copies Odin makes (Stage C's `exkCopy`), for the
  ## current snippet.
  t.needCmd(@["env", "TUCK_OWN=legacy", "TUCK_DEBUG_OWN=copies", "./tuck", "c",
              t.curDir / "t.tuck", "--odin", "-o:" & t.curDir / "outc"], vEmit)

proc verifyDump(t: var T): int =
  ## Rule V over the current snippet's Odin tree (the Stage C nodes today's
  ## passes wrote).
  t.needCmd(@["env", "TUCK_OWN=legacy", "TUCK_DEBUG_OWN=verify", "./tuck", "c",
              t.curDir / "t.tuck", "--odin", "-o:" & t.curDir / "outv"], vEmit)

proc rulesVerifyDump(t: var T): int =
  ## Rule V over the tree the RULES write (TUCK_OWN=rules, ownership_write).
  t.needCmd(@["env", "TUCK_OWN=rules", "TUCK_DEBUG_OWN=verify", "./tuck", "c",
              t.curDir / "t.tuck", "--odin", "-o:" & t.curDir / "outr"], vEmit)

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
  # Beside today's Nim `sink` (codegen_common.paramIsMovable), with the
  # reason P gives. Over every .tuck in the tree P and `sink` agree on 213
  # owning parameters and differ on 17, all of one kind — pinned below as
  # `bytesOf`: a final read handed to a runtime extern that only reads it,
  # which today's analysis takes to keep anything it cannot see into.
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
            "PARAM keepIt xs same (a sink at 8:10)"
  t.dumpHas p, "P: one only measured is borrowed", "PARAM lenOf xs same\n"
  t.dumpHas p, "P: one handed to a runtime reader is borrowed (today " &
               "over-approximates it as kept: the one kind of difference)",
            "PARAM bytesOf t today-only\n"
  t.dumpHas p, "P: one handed to a consuming parameter is consumed",
            "PARAM viaKeep xs same (keepIt keeps it at 17:15)"
  t.dumpHas p, "P: a `pending:` fn with no body is read by its " &
               "signature: a `str` in, a new `str` out, so it only reads it",
            "PARAM viaOpaque t today-only\n"
  t.dumpHas p, "P: a callee with no body is read by its signature: push's " &
               "result has its items' own type, a new Seq, so push only " &
               "reads them (today's `sink` says kept)",
            "PARAM grow xs today-only\n"
  t.dumpHas p, "P: a recursive reader borrows (the least fixed point)",
            "PARAM walk xs same\n"

  # --- rules D and M: where each owned place is dropped --------------------
  #
  # Beside the drops Stage C made from today's ownership pass. Over every
  # .tuck in the tree, on Odin: 343 owned slots agree; 27 are freed today
  # but not by the rules (19 twin parameters P says only borrow — the caller
  # drops them instead; 5 dead values today copies and then frees, which the
  # rules move; 3 handed to a `pending:` fn with no body); 52 are dropped by
  # the rules and leaked today (40 `str` locals, which on Odin wait on rule
  # G's static-or-heap answer; 12 Seqs today cannot prove owned). The one
  # real bug among them, a pushed element freed while held, was A40.
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
            "DROP keep xs - same moved"
  t.dumpHas dd, "D: an owned local nothing moves is dropped at its scope's end",
            "DROP main r - same owned"
  t.dumpHas dd, "M: moved on one path and kept on the other is `maybe`: " &
                "dropped, and reset where moved (today leaks it)",
            "DROP pick a - rules-only maybe"
  t.dumpHas dd, "D: a local only measured is dropped (today leaks it: its " &
                "read sits inside a call taken to carry everything out)",
            "DROP pick n - rules-only owned"

  # --- rule S: a sink moves at an owned place's final use, else copies -----
  #
  # Beside the copies Odin makes at a binding. Over every .tuck in the tree
  # no binding is copied by the rules and not today — the rules find no
  # aliasing today misses. Today copies 37 the rules do not: call results it
  # cannot prove fresh (a temporary is the binder's: any aliasing is copied
  # inside the callee), dead values it copies and then frees (which the rules
  # move), and two `str` literals copied to the heap (rule G's business).
  t.src """
import seq

fn take({xs: Seq[int]}) -> Seq[int]:
  var out = xs
  out = {items: out, value: 3} push
  return out

fn main() -> int:
  let a = [1, 2]
  let b = a
  let nested = [[1], [2]]
  let inner = nested[0]
  let t = {xs: b} take
  return a.len + inner.len + t.len + nested.len
"""
  let cd = t.copiesDump()
  t.dumpHas cd, "S: a place still read later is copied where it is bound",
            "COPY main 10:3 same rules=all today=all"
  t.dumpHas cd, "S: an element read is copied (it is never moved out of " &
                "its container)", "COPY main 12:3 same rules=all today=all"

  # --- rule V: the tree checked ----------------------------------------------
  #
  # compiler/ownership_check.nim reads the Odin tree as Stage C left it
  # (copies, drops, `dropsOld`) under today's convention (a moved twin owns
  # its first parameter; a call marked for the twin, or threaded through
  # it, hands its argument over). Over every .tuck in the tree it reports 11
  # places and 25 temporaries never dropped (A41-A45, each confirmed by
  # TUCK_TRACK), 3 borrowed values returned for the caller to copy (today's
  # provenance scheme, where rule S copies in the callee), and one list
  # holding live Seqs uncopied: sound today only because Odin's drop of a
  # Seq of Seqs is shallow.
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
  t.dumpLacks vd, "V: a moved twin's body owns, reads and drops its parameter: " &
                  "nothing to report", "VERIFY shrink"
  t.dumpHas vd, "V: a borrowed parameter's field handed over uncopied (today " &
                "the caller copies the result)",
            "VERIFY itemsOf borrowed-sunk b.items 20:11"
  t.dumpHas vd, "V: a local handed over at its last use leaks on the return " &
                "before it (A42)", "VERIFY early leak (some paths) xs 23:3"
  t.dumpHas vd, "V: a field overwritten without dropping what it held (A41)",
            "VERIFY refill overwrite-leak b.items 31:3"
  t.dumpHas vd, "V: a list holding a live Seq uncopied: the Seq is read after " &
                "it moved...", "VERIFY nest use-after-move a 38:21"
  t.dumpHas vd, "...and dropped after it moved", "VERIFY nest drop-after-move a 35:3"
  t.dumpHas vd, "V: a temporary only borrowed is never dropped (A45)",
            "VERIFY sumList temp-leak list 42:12"
  let rv = t.rulesVerifyDump()
  t.dumpLacks rv, "V: the tree the rules write (TUCK_OWN=rules) has none of " &
                  "these: every place dropped or moved once, every live " &
                  "read copied, every temporary named and dropped", "VERIFY"
  let gu = t.usesDump()
  t.classifies gu, "U: a generic record's construction takes its fields " &
                   "(`{items: xs} Box` is typed `Box[T]`)", "boxed xs sink final 17:18"
