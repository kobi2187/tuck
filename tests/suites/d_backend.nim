## Unit tests for the D backend, grown one milestone at a time — each
## milestone of compiler/codegen_d.nim lands with its assertions here.
##
## Two layers, mirroring odin_backend:
##   * emitsD/omitsD — the emitted text says what the backend decided
##     (cheap, runs in --quick).
##   * dmd build + RUN with an exit code — the decisions actually compute
##     (a compile-only check cannot see a wrong value; exit codes can).
##
## Skips with a notice when dmd is absent, unless TUCK_REQUIRE_D=1.

import std/[os, strutils]
import ../harness

proc runsD(t: var T, name: string, want: int, dmdExe: string) =
  ## Build the current snippet's emitted D with dmd and run it, asserting
  ## the exit code. Chained through the pool: emit -> dmd build -> run.
  let e = t.needD()
  let dir = t.curDir / "dlang"
  # minicoro.a rides along: tuck_rt re-exports the coroutine engine, so
  # every emitted program references its extern(C) symbols even when it
  # spawns nothing. `tuck c --dlang` already copies the archive beside the
  # emitted .d, so this just hands it to the linker.
  let b = t.needCmdAfter(@[dmdExe, "-i", "-I" & dir, dir / "t.d",
                           dir / "minicoro.a", "-of=" & dir / "prog"],
                         e, proc (dir: string) = discard, dir)
  let r = t.needCmdAfter(@[dir / "prog"], b,
                         proc (dir: string) = discard, dir)
  if t.phase == pCollect: return
  if t.skippedCmd(r): t.skip name; return
  let (brc, bout) = t.resultOf(b)
  if brc != 0:
    t.no name, "dmd build failed: " & bout.strip().splitLines()[^1]
    return
  let (rc, output) = t.resultOf(r)
  if rc == want: t.ok name
  else: t.no name, "exit " & $rc & ", want " & $want & ": " & output.strip()

proc runsDWith(t: var T, name: string, want: int, dmdExe: string,
               flags: seq[string], tag: string) =
  ## Like runsD, but with extra dmd flags — so a build MODE can be asserted,
  ## not just the source. The binary is named per tag so two modes of one
  ## snippet do not overwrite each other.
  let e = t.needD()
  let dir = t.curDir / "dlang"
  let bin = dir / ("prog_" & tag)
  let b = t.needCmdAfter(@[dmdExe, "-i", "-I" & dir] & flags &
                         @[dir / "t.d", dir / "minicoro.a", "-of=" & bin],
                         e, proc (dir: string) = discard, dir)
  let r = t.needCmdAfter(@[bin], b, proc (dir: string) = discard, dir)
  if t.phase == pCollect: return
  if t.skippedCmd(r): t.skip name; return
  let (brc, bout) = t.resultOf(b)
  if brc != 0:
    t.no name, "dmd build failed: " & bout.strip().splitLines()[^1]
    return
  let (rc, _) = t.resultOf(r)
  if rc == want: t.ok name
  else: t.no name, "exit " & $rc & ", want " & $want

proc run*(t: var T) =
  let dmdExe = findDmd()
  if dmdExe.len == 0:
    if t.phase != pReport: return
    if getEnv("TUCK_REQUIRE_D") == "1":
      echo "FAIL: dmd not found and TUCK_REQUIRE_D=1"
      t.failed.inc
      return
    echo "SKIP D backend check: dmd not found (set TUCK_REQUIRE_D=1 to require it)."
    echo "d_backend.sh: 0 passed, 0 failed"
    return

  # --- Milestone 1: plumbing ---------------------------------------------
  t.src """
import console

fn main() -> int:
  {text: "hello from tuck"} printLine
  return 7
"""
  t.emitsD "M1: entry module carries a valid D module header", "module t;"
  t.emitsD "M1: cross-module call is qualified through the import alias",
           r"console\.printLine\(""hello from tuck""\)"
  t.emitsD "M1: value-returning fn main IS the exit code, via native int main",
           r"int main\(string\[\] args\) \{"
  t.emitsD "M1: the entry point hands the command line to the runtime",
           r"rt\.tuckSetArgs\(args\);"
  t.emitsD "M1: Tuck int maps to 64-bit long, never D's 32-bit int",
           r"long tuck_main\(\)"
  t.runsD "M1: hello world builds with dmd and exits 7", 7, dmdExe

  # --- Milestone 2: statements & scalars ---------------------------------
  # T6-T9: declarations, arithmetic, control flow, ranges. The program's
  # exit code is a sum every construct contributes to — a wrong branch, a
  # wrong range bound or 32-bit wrap moves it.
  t.src """
fn main() -> int:
  var acc = 0
  for i in 1 ..< 11:
    acc = acc + i
  let d = 55 /i 5
  let m = 55 % 7
  let neg = 0 - 3
  var w = 0
  for w < 4:
    w = w + 1
  var skipped = 0
  for i in 0 .. 4:
    if i == 2:
      continue
    skipped = skipped + 1
  return acc + d + m + neg + w + skipped
"""
  t.emitsD "M2: first assignment declares with the checker's 64-bit type",
           "long acc = 0;"
  t.emitsD "M2: exclusive range is D's native exclusive foreach",
           r"foreach \(i; 1 \.\. 11\)"
  t.emitsD "M2: inclusive range widens the upper bound by one",
           r"foreach \(i; 0 \.\. 4 \+ 1\)"
  t.emitsD "M2: while-form for emits a native while", r"while \(\(w < 4\)\)"
  t.runsD "M2: control flow and arithmetic compute 77", 77, dmdExe

  # T10 + leftovers: strings, loop:, value-if, list iteration, echo.
  t.src """
import console
import seq

fn main() -> int:
  var s = "ab"
  s = s + "cd"
  {text: s} printLine
  let n = s.len
  var c = 0
  loop:
    c = c + 1
    if c == 3:
      break
  let pick = if c == 3: 10 else: 20
  let xs = [5, 6, 7]
  var total = 0
  for x in xs:
    total = total + x
  var idxSum = 0
  for i, x in xs:
    idxSum = idxSum + i
  total echo
  return n + c + pick + total + idxSum
"""
  t.emitsD "M2: string + is D's native concat, no runtime call",
           r"s = \(s ~ ""cd""\)"
  t.emitsD "M2: len is D's native length, cast back to Tuck's signed int",
           r"cast\(long\) s\.length"
  t.emitsD "M2: value-position if is D's native ternary",
           r"\(\(c == 3\) \? 10 : 20\)"
  t.emitsD "M2: index+value loop is D's native two-variable foreach",
           r"foreach \(i, x; xs\)"
  t.emitsD "M2: echo maps to writeln", r"writeln\(total\)"
  t.omitsD "M2: nothing reaches for a runtime concat helper", "tuckConcat"
  t.runsD "M2: strings, loop and lists compute 38", 38, dmdExe

  # --- Milestone 3: records, calls, objects, aliasing --------------------
  # T11/T15: record shapes hoist as named TRec structs; pending stubs are
  # function templates returning the zero value.
  t.src """
pending:
  fn fetch({url: str}) -> {hits: int, title: str}

fn main() -> int:
  let page = {url: "x"} fetch
  return page.hits
"""
  t.emitsD "M3: record shape hoists as a named TRec struct",
           r"struct TRec_hits_title_[0-9A-F]{4} \{"
  t.emitsD "M3: pending stub is a function template",
           r"tuck_fetch\(T\)\(T payload\) \{"
  t.emitsD "M3: pending stub logs to stderr like the Nim backend",
           r"stderr\.writeln\(""TUCK PENDING: tuck_fetch invoked"
  t.emitsD "M3: pending stub returns the zero value",
           r"return typeof\(return\)\.init;"
  t.runsD "M3: pending walking skeleton runs and returns the stub zero",
          0, dmdExe

  # T16: object member fns are qualified free procs; `self` is a D ref —
  # the mutation must reach the caller's var (1 then 2, not 1 then 1).
  t.src """
object Counter:
  total: int
  step: int

  fn bump({self: Counter}) -> int:
    self ..total {self.total + self.step}
    return self.total

fn main() -> int:
  var c = {total: 0, step: 3} Counter
  let r1 = {self: c} bump
  let r2 = {self: c} bump
  return c.total + r2 - r1
"""
  t.emitsD "M3: object emits a plain struct",
           r"struct tuck_Counter \{"
  t.emitsD "M3: member fn is a qualified free proc with ref self",
           r"long tuck_Counter_bump\(ref tuck_Counter self\)"
  t.emitsD "M3: record construction is a named-argument struct literal",
           r"tuck_Counter\(total: 0, step: 3\)"
  t.runsD "M3: self mutation persists across calls (6+6-3)", 9, dmdExe

  # T17: Tuck Seq assignment copies; a bare D slice assignment would alias.
  t.src """
import seq

fn firstOf({items: Seq[int]}) -> int:
  return items[0]

fn main() -> int:
  var a = [7, 8, 9]
  var b = a
  b[0] = 50
  let x = a firstOf
  return x + a[0] + b[0]
"""
  t.emitsD "M3: Seq assignment restores value semantics with .dup",
           r"long\[\] b = \(a\)\.dup;"
  t.runsD "M3: writing b never writes a (7+7+50)", 64, dmdExe

  # --- Milestone 4: sum types and match ----------------------------------
  # T18/T19, scoped to PAYLOAD-FREE sums: payload-carrying ones do not work
  # end to end in the Nim or Odin backends either (ledger DISCOVERIES), so
  # the authority has to be fixed before a third backend can follow it.
  t.src """
type Color:
  | Red
  | Green
  | Blue

fn rank({c: Color}) -> int:
  match c:
    Red: return 1
    Green: return 2
    Blue: return 3

fn main() -> int:
  let x = Color.Green
  let y = Color.Blue
  return ({c: x} rank) * 10 + ({c: y} rank)
"""
  t.emitsD "M4: a payload-free sum is a plain D enum",
           r"enum tuck_Color \{ Red, Green, Blue \}"
  t.emitsD "M4: match is a final switch — D re-checks the arms are exhaustive",
           r"final switch \(c\) \{"
  t.emitsD "M4: a bare tag qualifies to its enum, which D requires",
           r"case tuck_Color\.Red:"
  t.runsD "M4: match dispatches to the right arm (2*10+3)", 23, dmdExe

  # A match in VALUE position: D has no switch-expression, so the arms go
  # into an immediately-called lambda — which keeps the exhaustiveness check
  # that Odin's chained-ternary lowering loses.
  t.src """
type Color:
  | Red
  | Green
  | Blue

fn main() -> int:
  let c = Color.Green
  let code = match c:
    Red: 1
    Green: 2
    Blue: 3
  return code
"""
  t.emitsD "M4: value-position match keeps the exhaustive switch in a lambda",
           r"\(\(\) \{ final switch \(c\) \{"
  t.omitsD "M4: no chained ternary for a value match", r"\? 1 :"
  t.runsD "M4: value-position match yields the arm's value", 2, dmdExe

  # --- T20: !T / ?T as a value carrier -----------------------------------
  # Deliberately NOT D exceptions: Tuck's raise returns a value and .ok
  # inspects a status, where an exception unwinds non-locally. Same three
  # fields as tuck_rt.nim and tuck_rt.odin, same FNV error codes.
  t.src """
fn half({n: int}) -> !int [io]:
  if n % 2 != 0:
    return Error.odd
  return n /i 2

fn main() -> int [io]:
  let a = {n: 20} half
  let b = {n: 7} half
  if a.ok:
    if b.ok:
      return 1
    return a.value
  return 99
"""
  t.emitsD "T20: a fallible fn returns the carrier, not a bare value",
           r"rt\.TuckResult!\(long\) tuck_half\(long n\)"
  t.emitsD "T20: raise RETURNS an error value, carrying a compile-folded code",
           r"return rt\.terr!\(long\)\(0x[0-9A-F]{4} /\* odd \*/\)"
  t.emitsD "T20: a value return wraps in tok", r"return rt\.tok\(\(n / 2\)\);"
  t.emitsD "T20: .ok is a status test", r"a\.status == rt\.TuckStatus\.Ok"
  t.omitsD "T20: no exceptions anywhere near the error path", r"\bthrow\b"
  t.runsD "T20: the ok branch reads .value, the err branch does not", 10, dmdExe

  # A record payload and !void — the two shapes that need the runtime's own
  # types (a hoisted TRec, and TuckUnit for a result with nothing to carry).
  t.src """
fn readPort({port: int}) -> !{value: int} [io]:
  if port > 3:
    return Error.badPort
  return {value: 42}

fn touch({n: int}) -> !void [io]:
  if n < 0:
    return Error.negative
  return

fn main() -> int [io]:
  let good = {port: 1} readPort
  let bad = {port: 9} readPort
  let t = {n: 5} touch
  var acc = 0
  if good.ok:
    acc = acc + good.value.value
  if bad.ok:
    acc = acc + 1000
  if t.ok:
    acc = acc + 3
  return acc
"""
  t.emitsD "T20: a record payload rides in the carrier",
           r"rt\.TuckResult!\(TRec_value_[0-9A-F]{4}\) tuck_readPort"
  t.emitsD "T20: !void carries the unit struct, which D has no builtin for",
           r"rt\.TuckResult!\(rt\.TuckUnit\) tuck_touch"
  t.emitsD "T20: a bare return in a fallible fn still wraps",
           r"return rt\.tokVoid\(\);"
  t.runsD "T20: err results never take the ok branch (42+3)", 45, dmdExe

  # --- T22: invariants, on by default and opt-out only -------------------
  # ROADMAP 2026-08-25 ruling 5: invariants stay in a RELEASE build unless
  # the user asks to strip them. The Nim backend hardcodes
  # `when not defined(release)` and cannot honour that; this backend is
  # written to the ruling, and these assertions are what keep it honest.
  t.src """
type Temperature:
  celsius: f32
  invariant:
    celsius >= -273.15

fn main() -> int:
  let ok = {celsius: 20.0} Temperature
  return 0
"""
  t.emitsD "T22: the guard is opt-OUT, not release-stripped",
           r"version \(tuckNoInvariants\) \{\} else"
  t.emitsD "T22: a field in an invariant is reached through self",
           r"self\.celsius >= -273\.15"
  t.emitsD "T22: construction validates before the value flows on",
           r"__validated_tuck_Temperature\(tuck_Temperature\(celsius: 20\.0\)\)"
  t.omitsD "T22: not assert — dmd's -release strips those, undoing the ruling",
           r"assert\("
  t.runsD "T22: a satisfied invariant costs nothing observable", 0, dmdExe

  t.src """
type Temperature:
  celsius: f32
  invariant:
    celsius >= -273.15

fn main() -> int:
  let bad = {celsius: -300.0} Temperature
  return 0
"""
  # 134 = SIGABRT. The point is not the number but that it is NOT 0 in
  # either build: a violated invariant stops at the site.
  t.runsD "T22: a violated invariant aborts in a normal build", 134, dmdExe
  t.runsDWith "T22: and STILL aborts under -O -release (the ruling's teeth)",
              134, dmdExe, @["-O", "-release"], "rel"
  t.runsDWith "T22: stripped only when the user explicitly opts out",
              0, dmdExe, @["-version=tuckNoInvariants"], "off"

  # --- T24 (part): saturating, const, static assert ----------------------
  t.src """
type SafeRPM = u16 [saturating]

fn main() -> int:
  let over = 70000 SafeRPM
  let ok = 1200 SafeRPM
  if over == 65535 SafeRPM:
    return ok /i 100
  return 1
"""
  t.emitsD "T24: a saturating ctor clamps through the runtime, widened first",
           r"rt\.tuckSat!\(ushort\)\(cast\(ulong\)\(70000\)\)"
  t.runsD "T24: 70000 CLAMPS to 65535 rather than wrapping to 4464",
          12, dmdExe

  t.src """
const LIMIT = 8

static_assert LIMIT == 8

fn main() -> int:
  return LIMIT
"""
  t.emitsD "T24: a literal const is a D compile-time enum",
           r"enum tuck_LIMIT = 8;"
  t.emitsD "T24: static assert is checked by D at compile time, natively",
           r"static assert\("
  t.runsD "T24: the const reads back as its value", 8, dmdExe

  # --- fnsig: a callback slot is a bare function pointer -----------------
  t.src """
fnsig Adder = {a: int, b: int} -> int

type Calc = {add: Adder}

fn plus({a: int, b: int}) -> int:
  return a + b

fn main() -> int:
  let c = {add: :plus} Calc
  return {a: 40, b: 2} c.add
"""
  t.emitsD "fnsig: a named signature is a D function pointer, not a delegate",
           r"alias tuck_Adder = long function\(long a, long b\);"
  t.emitsD "fnsig: a fn used as a VALUE takes & — a bare name would call it",
           r"add: &tuck_plus"
  t.runsD "fnsig: calling through the slot runs the referenced fn", 42, dmdExe

  # --- the per-backend lowering seam -------------------------------------
  # `.dup` is decided by lowering_d (a tree pass), not by the emitter. The
  # assertion is the same either way — which is the point: the seam moved
  # the reasoning without changing the meaning.
  t.src """
import seq

fn main() -> int:
  var a = [7, 8, 9]
  var b = a
  b[0] = 50
  return a[0] + b[0]
"""
  t.emitsD "seam: lowering marks the Seq copy, the emitter only prints it",
           r"long\[\] b = \(a\)\.dup;"
  t.omitsD "seam: a fresh list literal owns its storage and needs no copy",
           r"= \(\[7, 8, 9\]\)\.dup"
  t.runsD "seam: writing b still never writes a (7+50)", 57, dmdExe

  # --- decision tables (spec 6.1) ----------------------------------------
  # The combinatorics come from codegen_table, shared with the other two
  # backends; only the spelling is D's. Enumerable columns collapse to one
  # switch over a packed key.
  t.src """
type Priority:
  | low
  | high

type Action:
  | drop
  | send

decision route({p: Priority, urgent: bool}) -> Action:
  | low   false -> drop
  | low   true  -> send
  | high  _     -> send

fn main() -> int:
  let a = {p: Priority.low, urgent: false} route
  if a == Action.drop:
    return 3
  return 1
"""
  t.emitsD "decision: enumerable columns collapse to one packed-key switch",
           r"switch \(cast\(long\)\(p\) \* 2 \+ cast\(long\)\(urgent\)\)"
  t.emitsD "decision: a packed key is an int, so the last group is default",
           r"default: return "
  t.runsD "decision: the table picks the first matching row", 3, dmdExe

  # --- C FFI (spec: extern [c, header: ...]) -----------------------------
  # THREE kinds of extern share the keyword and are not interchangeable:
  # runtime (tuck_rt forwarder), C FFI (a real symbol), and shim
  # (`impl: <backend> "module"`). These assertions cover the second.
  t.src """
extern [c, header: "math.h", lib: "m"]:
  type CPoint = {x: i32, y: i32}
  type CMode = {MODE_A = 3, MODE_B = 7}
  fn hypot({x: f64, y: f64}) -> f64

fn main() -> int:
  return 0
"""
  t.emitsD "ffi: a C fn is a native extern(C) declaration, no header needed",
           r"extern \(C\) double hypot\(double x, double y\);"
  t.emitsD "ffi: a system library links through pragma(lib)",
           r"pragma\(lib, ""m""\);"
  t.emitsD "ffi: a C struct is declared field-for-field with the C ABI",
           r"extern \(C\) struct CPoint \{"
  t.emitsD "ffi: a C enum keeps its explicit values",
           r"extern \(C\) enum CMode \{ MODE_A = 3, MODE_B = 7 \}"
  t.runsD "ffi: a program binding libm builds and runs", 0, dmdExe

  # An opaque handle: `type H = {}` is a typedef with no definition, so its
  # size is unknown and it can only be held as a pointer.
  t.src """
extern [c, header: "stdio.h"]:
  type CFile = {}

fn main() -> int:
  return 0
"""
  t.emitsD "ffi: a fieldless C type is an incomplete struct plus a pointer",
           r"struct CFileObj;\nalias CFile = CFileObj\*;"

  # --- tasks on the shared minicoro engine (spec 9.2) --------------------
  # Calling a task schedules a coroutine; binding its result awaits it. At
  # the source level that reads as an ordinary call — the effect marker IS
  # the async annotation, there is no await keyword.
  t.src """
fn stepIo({n: int}) -> {v: int} [io]:
  return {v: n}

task compute({base: int}) -> {r: int} [io]:
  let a = {n: base} stepIo
  let b = {n: base} stepIo
  return {r: a.v + b.v}

fn main() -> int:
  let res = {base: 21} compute
  return res.r
"""
  t.emitsD "task: a result-bound call spawns into a slot and awaits it",
           r"rt\.spawnResult\(tuckSlot\d+, \{ return tuck_compute\(21\); \}\)"
  t.emitsD "task: the await reads back through the slot",
           r"= rt\.awaitResult\(tuckSlot\d+\);"
  t.emitsD "task: a program with tasks boots the scheduler",
           r"rt\.tuckAsyncInit\(\);"
  t.emitsD "task: and drives it after main, so spawned work finishes",
           r"rt\.tuckRun\(\);"
  t.runsD "task: schedule + await computes 42 through a real coroutine",
          42, dmdExe

  # --- pools, registers, error policy ------------------------------------
  t.src """
pool Buffers = Array[8, u8] [count: 2]

fn main() -> int:
  let b = Buffers.acquire
  if b.ok:
    return 3
  return 1
"""
  t.emitsD "pool: one module-level instance of a fixed-count pool",
           r"__gshared rt\.ObjectPool!\(ubyte\[8\], 2\) tuck_Buffers;"
  t.emitsD "pool: acquire reaches the runtime intrinsic",
           r"rt\.acquire\(tuck_Buffers\)"
  t.runsD "pool: acquire yields a slot while any is free", 3, dmdExe

  t.src """
register RCC_CR at 0x40021000:
  HSION:   bit 0
  HSITRIM: bits 3..7

fn main() -> int:
  return 0
"""
  t.emitsD "register: a typed pointer at the MMIO address",
           r"__gshared uint\* tuck_RCC_CR = cast\(uint\*\)\(0x40021000\);"
  t.emitsD "register: a single bit reads as a bool",
           r"bool tuck_RCC_CR_HSION_get\(\)"
  t.emitsD "register: a range gets a width and a mask",
           r"enum uint tuck_RCC_CR_HSITRIM_MASK"

  # Error policy (spec 4.9). MOSTLY STATIC: `strict` is a compile error
  # listing every unhandled site, so a strict program reaches codegen with
  # no drop sites at all, and the SHORTCUTS report is the checker's. What
  # codegen owns is the handler and the call to it — `continue` carries on
  # past the drop, `exit` stops after the handler has run.
  t.src """
errors [policy: continue]:
  on unhandled({code: u16, site: str}):
    ...

fn readSensor({port: u8}) -> !{value: u16} [io]:
  if port > 3:
    return Error.badPort
  return {value: 42}

fn main() -> int [io]:
  {port: 9} readSensor
  return 7
"""
  t.emitsD "errors: the global handler is an ordinary fn",
           r"void tuck_unhandled\(ushort code, string site\)"
  t.emitsD "errors: a dropped result is captured, tested and routed",
           r"if \(tuckDrop\d+\.status != rt\.TuckStatus\.Ok\) \{ tuck_unhandled"
  t.omitsD "errors: continue fabricates no value — it just carries on",
           r"rt\.exit\(1\);"
  t.runsD "errors: continue runs the handler and reaches the next statement",
          7, dmdExe

  # --- interfaces: a copying tagged variant, NOT a vtable (spec 5.3) -----
  # Verified against both reference backends before implementing, in
  # scratchpad/iface-playground: Nim and Odin both return 12 on this
  # program, and the D backend had to match rather than merely compile.
  t.src """
interface Animal:
  fn noise({self: Self}) -> int

object Dog:
  satisfies Animal
  volume: int

  fn noise({self: Dog}) -> int:
    return self.volume

object Cat:
  satisfies Animal
  volume: int

  fn noise({self: Cat}) -> int:
    return self.volume * 100

fn hear({a: Animal}) -> int:
  return a.noise

fn report({d: Dog, c: Cat}) -> int:
  var dd = d
  let n1 = {a: dd} hear
  dd ..volume {9}
  let n2 = {a: dd} hear
  let n3 = {a: c} hear
  return n1 + n2

fn main() -> int:
  let d = {volume: 3} Dog
  let c = {volume: 5} Cat
  return {d: d, c: c} report
"""
  t.emitsD "iface: the variant carries a tag plus one field per satisfier",
           r"struct Animal \{\n    AnimalTag tag;"
  t.emitsD "iface: a wrap copies the concrete value in, tag and all",
           r"Animal\(AnimalTag\.Animal_is_tuck_Dog, tuck_DogVal: dd\)"
  t.omitsD "iface: no thunk per (type, member) — the spec's own claim",
           r"Animal_tuck_Dog_noise"
  t.runsD "iface: wrap copies (3), a later wrap sees 9, so 3+9=12",
          12, dmdExe

  # --- an inline sum in a field, and a member that declares no params ----
  # Two gaps that met in one program. `{Red, Yellow, Green}` is a sum with
  # no declaration, so it hoists to <Owner><Field>Kind — the same name the
  # Nim and Odin backends give it — and its tags must be qualified, since
  # a D enum member does not leak into module scope.
  #
  # `advance` declares no parameters at all. `self` is supplied by
  # lowering.normalizeSelf now, not by each backend for itself; before that
  # this emitted a fn taking nothing whose body still said `self`.
  t.src """
object Light:
  state: {Red, Yellow, Green}

  fn advance() -> int:
    return match self.state:
      Red:    1
      Green:  2
      Yellow: 3

fn main() -> int:
  let l = {state: Green} Light
  return l.advance
"""
  t.emitsD "inline sum: hoisted under <Owner><Field>Kind",
           r"enum tuck_LightStateKind \{ Red, Yellow, Green \}"
  t.emitsD "inline sum: a tag is qualified — D enum members do not leak",
           r"case tuck_LightStateKind\.Green:"
  t.emitsD "member with no declared params still takes self",
           r"tuck_Light_advance\(ref tuck_Light self\)"
  t.runsD "inline sum: state Green selects the second arm", 2, dmdExe

  # --- bake: a fn-typed slot is a FUNCTION POINTER, not a delegate -------
  # bake is fully lowered before codegen — what arrives is plain record
  # construction, so the only D-specific question is how to spell the type.
  # `function` and `delegate` are distinct types in D and what fills the
  # slot is a top-level fn with no captured environment. Nim's {.closure.}
  # and Odin's `proc` both accept a plain proc, so neither backend had to
  # make this choice.
  t.src """
fnsig BinOp = {a: int, b: int} -> int

fn plus({a: int, b: int}) -> int:
  return a + b

fn applyOperation({a: int, b: int, op: BinOp}) -> int:
  op.invoke {a, b}

fn main() -> int:
  let x = {a: 5, b: 10}
  let withOp = x bake {op: :plus}
  let smaller = withOp bake {b: 2}
  return smaller applyOperation
"""
  t.emitsD "fnsig: a function pointer, spelled with an alias",
           r"alias tuck_BinOp = long function\(long a, long b\)"
  t.emitsD "fnsig: filling the slot takes the fn's address",
           r"op: &tuck_plus"
  t.omitsD "fnsig: never a delegate — nothing here captures",
           r"delegate"
  t.runsD "bake: op=:plus then b=2, so 5+2", 7, dmdExe

  # --- composition: `+ Type` merges FIELDS, `+ Mixin` merges FNS ---------
  # Two different meanings for one `+` (spec §4.5, set union). Both are
  # materialised by lowering.composeObject now, so all three backends see a
  # plain object — before that each backend that had thought to do it kept
  # its own copy of the walk, and D, having none, could not compose at all.
  #
  # `crank` also chains: a `..` step emits as STATEMENTS, and statements
  # sequence rather than nest, so a chain feeding a later call runs into a
  # temp first (genDCallOnChain).
  t.src """
type AudioPlayer:
  volume: int

mixin BulkOps:
  fn bump(self, {by: int}) -> int:
    return by * 2

fn louder({self: Deck, step: int}) -> Deck:
  self

fn main() -> int:
  var d = {volume: 7} Deck
  return d.volume

object Deck:
  + AudioPlayer
  + BulkOps

  fn crank({step: int}) -> int:
    self ..louder {step}
    return self.volume
"""
  t.emitsD "compose: a composed type's field lands flat on the object",
           r"struct tuck_Deck \{\n    long volume;"
  t.emitsD "compose: a mixin fn materialises as a member of the object",
           r"tuck_Deck_tuck_bump\(ref tuck_Deck self"
  t.omitsD "compose: never embedded as a nested field",
           r"tuck_AudioPlayer audioPlayer"
  t.emitsD "chain: a standalone step writes back through the base",
           r"self = tuck_louder\(self, step\);"
  t.runsD "compose: the merged field is readable as the object's own", 7,
          dmdExe

  # A chain whose result IS consumed cannot write back through the base —
  # `report(self = louder(self, step))` is an assignment in an argument slot,
  # which none of the three targets accept. It runs into a temp instead, and
  # each step reads the PREVIOUS step's result (threadReceiver, shared with
  # the Nim backend) rather than the base.
  t.src """
fn louder({self: Deck, step: int}) -> Deck:
  self

fn report({self: Deck}) -> void:
  return

object Deck:
  volume: int

  fn crank({step: int}) -> void:
    self ..louder {step} .report

fn main() -> int:
  var d = {volume: 5} Deck
  return d.volume
"""
  t.emitsD "chain: a step feeding a call runs into a temp",
           r"tuck_Deck tuckChain1 = self;"
  t.emitsD "chain: the next step reads the temp, not the base",
           r"tuckChain1 = tuck_louder\(tuckChain1, step\)"
  t.omitsD "chain: the base itself is never written",
           r"self = tuck_louder"
  t.runsD "chain: the object is untouched, so volume is still 5", 5, dmdExe

  t.finish()
