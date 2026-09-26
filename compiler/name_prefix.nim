# compiler/name_prefix.nim
#
# HOW A TUCK NAME IS SPELLED IN THE OUTPUT — the rule alone, with no pass
# around it, so the modules below `mangle` (resolution, ast_query) can spell
# a name the same way instead of gluing a prefix on by hand.
#
#     tuckˑ<kind>ˑ<name>          fn order     -> tuckˑfnˑorder
#                                 type Order   -> tuckˑtypeˑOrder
#                                 actor Tally  -> tuckˑactorˑTally
#                                 a local n    -> tuckˑvˑn
#
# THE PREFIX SAYS EXACTLY WHAT THE NAME IS, and cannot be confused. Nim
# compares identifiers ignoring case and underscores after the first
# character, so with `_` between the parts `fn sigHandler`
# (tuck_fn_sigHandler) and `fnsig Handler` (tuck_fnsig_Handler) were one
# identifier to Nim, and so were a local `typeName` and `type Name`.
#
# The separator is `ˑ` (U+02D1), a Unicode LETTER — which is what lets all
# three hosts take it in an identifier (checked: Nim, Odin and dmd each build
# and link it) — and it is outside Tuck's own alphabet: the lexer takes only
# ASCII in a name. So, by construction rather than by a list:
#
#   * The kind is always recoverable: it is the ASCII word between the first
#     two separators, and no name part can contain one. Two names of
#     different kinds differ there, however their names are spelled.
#   * No source name can look already renamed, so `isMangledName` is a sound
#     test of it with nothing reserved.
#   * No runtime or compiler-made name (all ASCII) can meet a user name — the
#     old `tuck_val_` spelling and its list of runtime names a local could
#     fold into are gone.
#
# One-way and rarely read by a person; that it cannot collide is the point.
#
# (Not `mangle_name.nim`: to Nim that module name IS `mangleName`, the proc
# every emitter imports from `mangle` — the same folding, one level up.)
import strutils
import ast

type NameKind* = enum
  ## What a name is, and the word its mangled form carries. One per kind of
  ## declaration the renaming pass touches, plus the two kinds of name that
  ## are not declarations: a local, and a sum variant's tag field.
  nkLocal = "v"            ## a local or a parameter
  nkFn = "fn"              ## a fn — a pending one, a mixin member
  nkTask = "task"
  nkDecision = "decision"  ## a decision table
  nkType = "type"
  nkObject = "object"
  nkActor = "actor"
  nkFnSig = "fnsig"
  nkConst = "const"
  nkPool = "pool"
  nkRegister = "register"
  nkRegistry = "registry"
  nkVariant = "variant"    ## the tag field of a payload-carrying sum variant

const KindSeparator = "ˑ"   ## U+02D1: a letter to every host, never to Tuck
const MangledPrefix* = "tuck" & KindSeparator
  ## What every mangled name starts with, and no source name can.

static:
  doAssert KindSeparator[0].ord >= 128,
    "name_prefix: the separator must lie outside the ASCII a Tuck name is " &
    "written in, or a source name could spell a generated one"
  for k in NameKind:
    for c in $k:
      doAssert c in {'a'..'z'},
        "name_prefix: the kind word '" & $k & "' must be lowercase ASCII"

proc isMangledName*(name: string): bool =
  ## Already in its output spelling — the pass must be idempotent, since
  ## each backend lowers its own deep copy and re-runs it.
  name.startsWith(MangledPrefix)

proc prefixed*(name: string, kind: NameKind): string =
  ## `name` spelled as a `kind`.
  MangledPrefix & $kind & KindSeparator & name

proc declKind*(d: Decl): NameKind =
  ## The word a declaration's mangled name carries: exactly what it is. Asked
  ## only of the kinds the renaming pass touches — the rest emit no name of
  ## their own, so reaching one here is a bug in the caller.
  case d.kind
  of dkFn: (if d.isDecision: nkDecision else: nkFn)
  of dkTask: nkTask
  of dkType: nkType
  of dkObject: nkObject
  of dkActor: nkActor
  of dkFnSig: nkFnSig
  of dkConst: nkConst
  of dkPool: nkPool
  of dkRegister: nkRegister
  of dkRegistry: nkRegistry
  of dkMixin, dkExtern, dkPending, dkExpr, dkStaticAssert, dkErrors,
     dkResources, dkImport, dkSelect, dkSatisfies, dkInterface, dkGroup,
     dkPublic, dkWhen:
    raiseAssert "name_prefix: a " & $d.kind & " declares no emitted name"
