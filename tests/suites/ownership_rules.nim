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
  t.needCmd(@["env", "TUCK_DEBUG_OWN=uses", "./tuck", "c",
              t.curDir / "t.tuck", "--odin", "-o:" & t.curDir / "out"], vEmit)

proc paramsDump(t: var T): int =
  ## Rule P beside today's Nim `sink`, for the current snippet.
  t.needCmd(@["env", "TUCK_DEBUG_OWN=params", "./tuck", "c",
              t.curDir / "t.tuck", "-o:" & t.curDir / "outp"], vEmit)

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
  ## Registers the rule U classification and rule P assertions.
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
  t.dumpHas p, "P: a callee with no body is taken to keep it (the safe " &
               "default)", "PARAM viaOpaque t same (opaque has no body"
  t.dumpHas p, "P: the runtime table says push keeps its items",
            "PARAM grow xs same (the runtime's push keeps it at 23:18)"
  t.dumpHas p, "P: a recursive reader borrows (the least fixed point)",
            "PARAM walk xs same\n"
