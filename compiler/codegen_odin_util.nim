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
#   * pure AST predicates — what does this pattern print as, which enum owns
#                           a variant tag
import ast, ast_query, strutils

proc odinLibSpec*(lib: string): string =
  ## `lib: "..."` -> Odin's `foreign import` spec. A bare name is a system
  ## library; a path rides through as-is. `.c` names vendored SOURCE, which
  ## Odin cannot compile — the Nim backend takes it via {.compile.}, so here it
  ## becomes the object file the project's build is expected to have produced.
  ##
  ## No `lib:` at all — `extern [c, header: "string.h"]` — is the C standard
  ## library, which every C program links anyway; foreignLibAlias names it
  ## `libc`. It used to print `"system:"`, which Odin refuses outright.
  if lib == "": "system:c"
  elif lib.endsWith(".c"): lib[0 ..< lib.len - 2] & ".o"
  elif '/' in lib or lib.endsWith(".a") or lib.endsWith(".so") or lib.endsWith(".o"): lib
  else: "system:" & lib

# repeat/capitalize are NOT here: they are strutils', re-exported by ast_query,
# which this backend already imports. They were private duplicates in
# codegen_odin.nim that local shadowing kept invisible until the split
# widened their scope and Nim reported the ambiguity.

proc errCodeLit*(name: string): string =
  ## An error variant's code as an Odin literal: its stable hash in hex, with
  ## the variant's name in a trailing comment for whoever reads the output.
  "0x" & toHex(errIdCode(name)) & " /* " & name & " */"

# genPatternStr is NOT here either — same story as repeat/capitalize:
# ast_query already exports it.

var tagOwnerHint* = ""
  ## The sum type the surrounding place expects (a `match` subject's type, the
  ## checker's type for a bare variant). When two sum types declare a tag, the
  ## owner is THIS one, not whichever is declared first (issue #102).

proc hintOf*(t: Type): string =
  ## The name to put in `tagOwnerHint` for a place of type `t`.
  if t != nil and t.kind == tkNamed: t.name else: ""

template withTagHint*(t: Type, body: untyped) =
  let savedTagHint = tagOwnerHint
  tagOwnerHint = hintOf(t)
  try: body
  finally: tagOwnerHint = savedTagHint

proc ownsTag(d: Decl, tag: string): bool =
  ## Is `d` a declared sum with a variant called `tag`?
  if d == nil or d.kind != dkType or d.typeBody == nil or
     d.typeBody.kind != tkSum: return false
  for v in d.typeBody.variants:
    if v.name == tag: return true

proc tagEnumName(d: Decl): string =
  ## The enum the tags of sum `d` live on: its `<Name>Kind` when any variant
  ## carries a payload, else the sum itself.
  for v in d.typeBody.variants:
    if v.fields.len > 0: return d.name & "Kind"
  d.name

proc enumTagOwner*(m: Module, tag: string): string =
  ## The declared enum (or its Kind enum) that owns a variant tag, if any.
  ## A payload sum's tags live on its `<Name>Kind` enum, so that is the owner.
  ## When two sums share the tag, the hinted one wins (issue #102); otherwise
  ## the first declared. Empty when no declared sum has the tag (an inline sum).
  if tagOwnerHint != "":
    for d in m.decls:
      if d != nil and d.name == tagOwnerHint and d.ownsTag(tag):
        return d.tagEnumName
  for d in m.decls:
    if d.ownsTag(tag): return d.tagEnumName
  ""
