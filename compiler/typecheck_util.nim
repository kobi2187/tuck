# compiler/typecheck_util.nim
#
# Stateless type-checker helpers: pure functions over Type that need no
# TypeChecker context. Factored out so the checker's synthesis, flow, and
# validation modules can all share them without threading state.
import ast, semantics, tables, strutils, sets
import diagnostics
export diagnostics   # every fail() caller needs the codes


proc typeParamType*(sp: Span): Type =
  ## A generic's `T` inside its own body: not unknown, ANY type, fixed per call
  ## site. `fn identity[T]({x: T}) -> T` checks its body once with T abstract.
  Type(span: sp, kind: tkNamed, name: TypeParamName)

proc typeParamNamed*(sp: Span, g: string): Type =
  ## The same abstraction, but carrying WHICH parameter it is —
  ## `<typeparam:K>`. Every `T` in a body used to collapse to one nameless
  ## sentinel, so `fn mk[K, V]({k: K, v: V}) -> Pair[K, V]` could not
  ## construct its own return type: the checker saw two indistinguishable
  ## abstractions and reported "cannot infer generic parameter 'K'".
  ## Everything that treated a type param as unknown still does — the name
  ## is read only where a binding needs to know which one it was.
  Type(span: sp, kind: tkNamed, name: NamedTypeParamPrefix & g & ">")

proc pendingType*(sp: Span): Type =
  ## Declared, not implemented (spec §5.4). Deliberately permissive: the whole
  ## point of the walking skeleton is that the program compiles and runs.
  Type(span: sp, kind: tkNamed, name: PendingName)

proc emptyRecType*(sp: Span): Type =
  ## `{}` — the empty record. A real type, not an absence of one.
  Type(span: sp, kind: tkNamed, name: EmptyRecName)

proc afterErrorType*(sp: Span): Type =
  ## Returned after fail() has already reported. Nothing should check it; it
  ## exists only because the code path needs a Type to return.
  Type(span: sp, kind: tkNamed, name: AfterErrorName)

proc branchOutcomeType*(sp: Span): Type =
  ## `on select:` as a task's own tail expression: every arm returns
  ## explicitly, so nothing ever reads the construct's own synthesized
  ## value — there is no real type to report, and unlike `the old missing-type sentinel`
  ## this is not a gap the checker failed to work out.
  Type(span: sp, kind: tkNamed, name: BranchOutcomeName)

proc isTypeParam*(t: Type): bool =
  t != nil and t.kind == tkNamed and
    (t.name == TypeParamName or t.name.startsWith(NamedTypeParamPrefix))

proc typeParamName*(t: Type): string =
  ## Which type parameter a `<typeparam:K>` stands for, or "" for the
  ## nameless form.
  if t == nil or t.kind != tkNamed: return ""
  if not t.name.startsWith(NamedTypeParamPrefix): return ""
  t.name[NamedTypeParamPrefix.len .. ^2]

proc isPending*(t: Type): bool =
  t != nil and t.kind == tkNamed and t.name == PendingName

proc isFlexible*(t: Type): bool =
  ## True only for types that are intentionally abstract or exist solely as
  ## control-flow bookkeeping. Missing types are represented by nil during
  ## local inference and are never stamped onto the typed AST.
  t == nil or (t.kind == tkNamed and
               (t.name in [TypeParamName, PendingName, EmptyRecName,
                           AfterErrorName, BranchOutcomeName] or
                t.name.startsWith(NamedTypeParamPrefix)))

const NumericNames* = ["int", "i8", "i16", "i32", "i64",
                       "u8", "u16", "u32", "u64", "usize",
                       "f32", "f64", "float"].toHashSet

proc isNumeric*(t: Type): bool =
  t != nil and t.kind == tkNamed and t.name in NumericNames

proc fail*(msg: string, span: Span) =
  let err = newException(SemanticError, msg & " at line " & $span.line & ":" & $span.col)
  err.line = span.line
  err.col = span.col
  raise err

proc fail*(dc: DiagCode, msg: string, span: Span) =
  ## The same rejection, carrying a lookup code (`TK-TY01: expects int but got
  ## str`). The uncoded overload above still works, so codes are adopted site
  ## by site rather than in one sweep — see diagnostics.nim.
  fail(withCode(dc, msg), span)

# `!T` / `?T` / `!?T` parse as tkApp with a tkNamed base of "!", "?" or "!?".
proc isWrapper*(t: Type): bool =
  t != nil and t.kind == tkApp and t.base != nil and t.base.kind == tkNamed and
    t.base.name in ["!", "?", "!?"] and t.args.len == 1

proc unwrapEffect*(t: Type): Type =
  if isWrapper(t):
    return unwrapEffect(t.args[0])
  t

# `<uninit>[T]` — a declared field the construction did not supply. Shares
# tkApp's shape with the wrappers above but is deliberately NOT one of them:
# `!`/`?` are written by the author in a signature, this is inferred by the
# checker and never spelled in source. Adding it to isWrapper would make every
# wrapper site tell the user to guard something they never declared.
proc isUninit*(t: Type): bool =
  t != nil and t.kind == tkApp and t.base != nil and t.base.kind == tkNamed and
    t.base.name == UninitName and t.args.len == 1

proc unwrapUninit*(t: Type): Type =
  ## The field's real type, marker removed. Used wherever the QUESTION is
  ## "what shape is this?" rather than "may I read it?" — record compatibility,
  ## and the boundary where a type is stamped for codegen.
  if isUninit(t): t.args[0] else: t

proc stripUninit*(t: Type): Type =
  ## A record with every field's marker removed — the shape it will have once
  ## the holes are filled. For comparisons that ask "is this the right TYPE?"
  ## rather than "may I read this?".
  if t == nil or t.kind != tkRecord: return unwrapUninit(t)
  var fs: seq[FieldDef]
  for f in t.fields:
    fs.add(FieldDef(name: f.name, typ: stripUninit(f.typ), span: f.span))
  Type(span: t.span, kind: tkRecord, fields: fs)

proc anyUninit*(t: Type): bool =
  ## Does this record carry a hole, at any depth? Recursive, so an Outer whose
  ## Inner has one still answers yes and keeps its structural type instead of
  ## collapsing back to the nominal declaration.
  if t == nil or t.kind != tkRecord: return false
  for f in t.fields:
    if isUninit(f.typ) or anyUninit(f.typ): return true
  false

proc markUninit*(t: Type, sp: Span): Type =
  ## Wrap a field's type as unsupplied. Idempotent: marking twice is the same
  ## as marking once, which keeps re-entrant construction paths honest.
  if isUninit(t): t
  else: Type(span: sp, kind: tkApp, args: @[t],
             base: Type(span: sp, kind: tkNamed, name: UninitName))

proc typeName*(t: Type): string =
  if t == nil: return "void"
  case t.kind
  of tkNamed: t.name
  of tkRecord:
    var parts: seq[string]
    for f in t.fields: parts.add(f.name & ": " & typeName(f.typ))
    "{" & parts.join(", ") & "}"
  of tkApp:
    if t.base != nil and t.base.kind == tkNamed and t.base.name in ["!", "?", "!?"]:
      t.base.name & typeName(t.args[0])
    elif isUninit(t):
      # reads as a state of the field, not a container of it
      typeName(t.args[0]) & " " & UninitName
    else:
      var parts: seq[string]
      for a in t.args: parts.add(typeName(a))
      typeName(t.base) & "[" & parts.join(", ") & "]"
  of tkSum: "sum type"
  of tkUnion: "union type"
  else: "<type>"

proc substituteType*(t: Type, b: Table[string, Type]): Type =
  if t == nil or b.len == 0: return t
  case t.kind
  of tkNamed:
    if b.hasKey(t.name): return b[t.name]
    t
  of tkApp:
    var args: seq[Type]
    for a in t.args: args.add(substituteType(a, b))
    Type(span: t.span, kind: tkApp, attrs: t.attrs,
         base: substituteType(t.base, b), args: args)
  of tkFunc:
    var ps: seq[Type]
    for p in t.params: ps.add(substituteType(p, b))
    Type(span: t.span, kind: tkFunc, params: ps, paramNames: t.paramNames,
         result: substituteType(t.result, b))
  of tkRecord:
    var fields: seq[FieldDef]
    for f in t.fields:
      fields.add(FieldDef(name: f.name, typ: substituteType(f.typ, b), span: f.span))
    Type(span: t.span, kind: tkRecord, attrs: t.attrs, fields: fields)
  else: t
