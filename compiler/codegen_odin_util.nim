# compiler/codegen_odin_util.nim
#
# Odin-backend helpers that need no OdinCodegenCtx. Split out of
# codegen_odin.nim, which was the largest file in the compiler.
#
# The seam is the same one used to split the Nim backend: everything here is a
# pure function of its arguments — a string, or a plain AST node — so it sits
# BELOW the backend in the dependency DAG and cannot call back up into
# expression emission. Anything wanting `ctx` (patternValue reading
# ctx.module, armValue reaching genOdinExpr) stays in codegen_odin.nim where
# the context lives.
#
# Two groups:
#   * emission utilities  — library specs, string padding, error-code hashing
#   * pure AST predicates — is this fn a decision table, what does this
#                           pattern print as, which enum owns a variant tag
import ast, strutils

proc odinLibSpec*(lib: string): string =
  ## `lib: "..."` -> Odin's `foreign import` spec. A bare name is a system
  ## library; a path rides through as-is. `.c` names vendored SOURCE, which
  ## Odin cannot compile — the Nim backend takes it via {.compile.}, so here it
  ## becomes the object file the project's build is expected to have produced.
  if lib.endsWith(".c"): lib[0 ..< lib.len - 2] & ".o"
  elif '/' in lib or lib.endsWith(".a") or lib.endsWith(".so") or lib.endsWith(".o"): lib
  else: "system:" & lib

# repeat/capitalize are NOT here: they are strutils', re-exported by ast_query,
# which this backend already imports. They were private duplicates in
# codegen_odin.nim that local shadowing kept invisible until the split
# widened their scope and Nim reported the ambiguity.

# Same FNV-1a fold as tuck_rt.nim's errCode: the emitter precomputes error
# codes so the runtime needs no compile-time hashing.
proc odinErrCode*(name: string): uint16 =
  var h = 2166136261'u32
  for c in name:
    h = (h xor uint32(c)) * 16777619'u32
  uint16((h xor (h shr 16)) and 0xFFFF'u32)

proc errCodeLit*(name: string): string =
  "0x" & toHex(odinErrCode(name)) & " /* " & name & " */"

# isDecisionTable/genPatternStr are NOT here either — same story as
# repeat/capitalize: ast_query already exports both, byte-identical.

# The declared enum (or its Kind enum) that owns a variant tag, if any.
proc enumTagOwner*(m: Module, tag: string): string =
  for d in m.decls:
    if d != nil and d.kind == dkType and d.typeBody != nil and
       d.typeBody.kind == tkSum:
      for v in d.typeBody.variants:
        if v.name == tag:
          var hasPayload = false
          for vv in d.typeBody.variants:
            if vv.fields.len > 0: hasPayload = true
          return (if hasPayload: d.name & "Kind" else: d.name)
  return ""
