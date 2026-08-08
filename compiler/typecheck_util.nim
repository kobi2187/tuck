# compiler/typecheck_util.nim
#
# Stateless type-checker helpers: pure functions over Type that need no
# TypeChecker context. Factored out so the checker's synthesis, flow, and
# validation modules can all share them without threading state.
import ast, semantics, tables, strutils, sets
import diagnostics
export diagnostics   # every fail() caller needs the codes

proc unknownType*(sp: Span): Type =
  ## The checker could not work this type out. A GAP — every one found so far
  ## turned out to be a bug it was hiding, so prefer one of the named sentinels
  ## below whenever the situation actually has a name.
  Type(span: sp, kind: tkNamed, name: UnknownName)

proc typeParamType*(sp: Span): Type =
  ## A generic's `T` inside its own body: not unknown, ANY type, fixed per call
  ## site. `fn identity[T]({x: T}) -> T` checks its body once with T abstract.
  Type(span: sp, kind: tkNamed, name: TypeParamName)

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

proc isTypeParam*(t: Type): bool =
  t != nil and t.kind == tkNamed and t.name == TypeParamName

proc isPending*(t: Type): bool =
  t != nil and t.kind == tkNamed and t.name == PendingName

proc isUnknown*(t: Type): bool =
  ## True for every sentinel, so existing call sites keep their present
  ## behaviour while the meanings are separated one at a time. Narrowing this
  ## to UnknownName alone is what finally makes a checker gap an error.
  t == nil or (t.kind == tkNamed and
               t.name in [UnknownName, TypeParamName, PendingName,
                          EmptyRecName, AfterErrorName])

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
  of tkRecord:
    var fields: seq[FieldDef]
    for f in t.fields:
      fields.add(FieldDef(name: f.name, typ: substituteType(f.typ, b), span: f.span))
    Type(span: t.span, kind: tkRecord, attrs: t.attrs, fields: fields)
  else: t
