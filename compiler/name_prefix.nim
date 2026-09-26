# compiler/name_prefix.nim
#
# HOW A TUCK NAME IS SPELLED IN THE OUTPUT — the rule alone, with no pass
# around it, so the modules below `mangle` (resolution, ast_query) can spell
# a name the same way instead of gluing a prefix on by hand.
#
# THE PREFIX SAYS WHAT THE NAME IS (#78). Nim compares identifiers ignoring
# case and underscores after the first character, so under one fixed `tuck_`
# prefix `type Order` and `fn order` became `tuck_Order` and `tuck_order` —
# one identifier to Nim, "redefinition of 'tuck_order'". A fn and a type now
# live under different prefixes, `tuck_fn_order` and `tuck_type_Order`, so
# they cannot meet however they are cased, on any backend.
#
# (Not `mangle_name.nim`: to Nim that module name IS `mangleName`, the proc
# every emitter imports from `mangle` — the same folding, one level up.)
import strutils

type NameKind* = enum
  nkValue   ## a const, pool, register, registry, local — `tuck_`
  nkFn      ## a fn or task — `tuck_fn_`
  nkType    ## a type, object, actor or fn signature — `tuck_type_`

const TuckNamePrefix* = "tuck_"
const FoldSafePrefix* = "tuck_val_"
  ## a VALUE whose `tuck_` spelling Nim folds into a runtime intrinsic
  ## (mangle.RtFoldableIntrinsics). Was `tuckfn_`, which to Nim is `tuck_fn_`.

proc isMangledName*(name: string): bool =
  ## Already in its output spelling — the pass must be idempotent, since
  ## each backend lowers its own deep copy and re-runs it. Every prefix
  ## starts with `tuck_`.
  name.startsWith(TuckNamePrefix)

proc prefixed*(name: string, kind: NameKind): string =
  ## `name` with the prefix of its kind.
  case kind
  of nkValue: TuckNamePrefix & name
  of nkFn: TuckNamePrefix & "fn_" & name
  of nkType: TuckNamePrefix & "type_" & name
