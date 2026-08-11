## `extern [impl: nim "...", odin "..."]` — naming the backend-language module
## that implements a header-less extern block.
##
## Before this existed there were exactly two ways to bind anything: a C header
## (`extern [c, header:]`), or adding a proc to compiler/tuck_rt.nim and its
## hand-mirrored Odin twin. So every stdlib block cost an edit to the compiler's
## own runtime, twice. `impl:` makes the stdlib growable from outside the
## compiler, which is what the ~95-block catalogue in stdlib-blocks.md needs.
##
## The Tuck signature is the contract and both backends converge on it: Nim can
## re-export unqualified, Odin cannot, so the Odin side gets a generated
## forwarder into the aliased package. Call sites are identical either way.

import std/[os, strutils, re]
import ../harness

proc run*(t: var T) =
  # --- a real Nim stdlib proc, with no tuck_rt.nim edit --------------------

  t.src """
extern [impl: nim "std/strutils"]:
  fn startsWith({s: str, prefix: str}) -> bool

fn main() -> int:
  if {s: "hello", prefix: "he"} startsWith:
    return 7
  return 9
"""
  t.okCheck "impl: nim parses and checks"
  t.emits    "the impl module is imported",    "import std/strutils"
  # Nim exports by MODULE NAME, not by path: `export std/strutils` is a syntax
  # error, so the basename is what gets re-exported.
  t.emits    "and re-exported by basename",    "export strutils"
  t.runs     "the bound Nim proc really runs", 7

  # --- a backend-language module name is NOT a path ------------------------

  # "std/strutils" and "core:strings" name modules in the backend's own
  # namespace. Only ./ and ../ mark a path relative to the .tuck source, so these
  # must ride through untouched however -o: moves the output.
  t.src """
extern [impl: nim "std/strutils", odin "core:strings"]:
  fn startsWith({s: str, prefix: str}) -> bool

fn main() -> int:
  return 0
"""
  t.emits     "nim module name passes through",  "import std/strutils"
  t.emitsOdin "odin module name passes through", "import strings \"core:strings\""

  # --- Odin gets a forwarder, because it has no unqualified import ---------

  t.src """
extern [impl: odin "core:strings"]:
  fn startsWith({s: str, prefix: str}) -> bool

fn main() -> int:
  if {s: "hello", prefix: "he"} startsWith:
    return 7
  return 9
"""
  t.emitsOdin "odin forwards into the aliased package", "return strings\\.startsWith"
  # The call site stays unqualified — identical to the Nim backend's.
  t.emitsOdin "odin call site is unqualified",          "if startsWith\\("

  # --- both backends, one signature, end to end ----------------------------

  # examples/34-ffi-cstring is the real case this was built for: libz's version
  # is a C `char*`, which the params-only pointer rule forbids from crossing into
  # Tuck. The binding declares `-> str` and each backend's shim
  # (examples/shim/zlib_shim.nim / .odin) copies it. Asserted on the Nim side by
  # running it; the Odin side is gated by tests/odin_backend.sh.
  let zdir = t.dir / "z"
  let zb = t.needCmd @["./tuck", "build", "examples/34-ffi-cstring.tuck",
                       "-o:" & zdir, "--root:" & t.root]
  let zr = t.needCmdAfter(@[zdir / "m_34_ffi_cstring"], zb,
                          proc (dir: string) = discard, zdir)
  if t.phase == pReport:
    let (brc, blog) = t.resultOf(zb)
    if brc != 0:
      # The LAST TWO lines, or fewer if that is all there is. A one-line
      # failure used to crash the whole suite here (`[^2 .. ^1]` indexing -1),
      # which killed every test after it and hid the failure it was reporting.
      # Front-end rejections are one line; only Nim's own errors carry a hint.
      let blines = blog.strip(leading = false).splitLines()
      t.no "34-ffi-cstring builds", blines[max(blines.len - 2, 0) .. ^1].join("\n")
    else:
      let (rc, outp) = t.resultOf(zr)
      if rc != 0:
        t.no "34-ffi-cstring runs", "exit " & $rc & ", want 0"
      elif find(outp, re"(?m)^[0-9]+\.[0-9]") >= 0:
        t.ok "34-ffi-cstring prints libz's real version (" & outp.strip & ")"
      else:
        t.no "34-ffi-cstring prints libz's real version", "got: " & outp

  # The path in that example is written ./shim/... — relative to the .tuck file,
  # which is the only frame of reference its author has. -o: moves the output, so
  # the compiler rebases it; the author never adjusts what they wrote.
  t.src """
extern [impl: nim "./nowhere/mod"]:
  fn f() -> int

fn main() -> int:
  return 0
"""
  t.emits "a ./ path is rebased off the output dir", "import \\.\\..*nowhere/mod"

  t.finish()
