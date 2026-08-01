# compiler/codegen_type.nim
#
# Tuck type -> Nim type text. Split out of codegen.nim, which was doing the
# whole backend in one file; this is the part that answers ONE question and
# needs nothing else to answer it.
#
# Why this is the safe piece to lift out: genType is a pure function of the
# type node. No CodegenCtx, no module, no mutation — so it sits BELOW codegen
# in the dependency DAG and can never need to call back up into expression
# emission. That is the whole test for what belongs here. Anything that wants
# `ctx` (fieldType hoisting an inline enum, saturatingBase reading the decl
# index) stays in codegen.nim where the context lives.
#
# The Odin backend has its own odinType in codegen_odin.nim rather than
# sharing this one, and deliberately so — per codegen.nim's header rule:
# share the logic, never share the syntax. `uint32` vs `u32` IS the target
# language, not incidental duplication.
import ast, strutils

proc genType*(t: Type): string =
  if t == nil: return "void"
  case t.kind
  of tkNamed:
    case t.name
    of "void": "void"
    of "u8": "uint8"
    of "u16": "uint16"
    of "u32": "uint32"
    of "u64": "uint64"
    of "i8": "int8"
    of "i16": "int16"
    of "i32": "int32"
    of "i64": "int64"
    of "int": "int"
    of "string", "str": "string"
    # C's char* — the FFI boundary type. Distinct from `string`, which is a
    # GC'd length-prefixed object Nim will not hand to a C function.
    of "cstring": "cstring"
    # C's uint8_t* — cstring's byte-array sibling, for the pointer+length shape
    # every buffer syscall wants (memcpy, read, send). Seq[u8] cannot play this
    # role: it is a GC'd object with a length header, and passing one to C hands
    # over the header, not the bytes.
    #
    # Builtin rather than a user-declared `type Buf = {}` inside an extern
    # block: that route emits {.importc: "Buf", header: "...".}, claiming a C
    # typedef named Buf exists in that header. For a real opaque handle
    # (`typedef struct Counter Counter;`) that claim is true; for an anonymous
    # byte pointer there is no such name, and it only survives because
    # incompleteStruct means Nim never asks C to resolve it.
    of "Buf": "ptr UncheckedArray[uint8]"
    of "bool": "bool"
    of "float": "float"
    of "f32": "float32"
    of "f64": "float64"
    of "usize": "uint"
    of "Seq": "seq"
    of "Array": "array"
    of "fn": "auto"  # fn slot: generic param — Nim monomorphizes per bake
    else:
      # Odd bit widths from decision tables (u2, u12, ...) round up to a real int
      if t.name.len >= 2 and t.name[0] in {'u', 'i'} and t.name[1..^1].allCharsInSet({'0'..'9'}):
        let bits = parseInt(t.name[1..^1])
        let base = if t.name[0] == 'u': "uint" else: "int"
        if bits <= 8: base & "8"
        elif bits <= 16: base & "16"
        elif bits <= 32: base & "32"
        else: base & "64"
      else: t.name
  of tkTuple:
    var parts: seq[string]
    for e in t.elems: parts.add(genType(e))
    "(" & parts.join(", ") & ")"
  of tkApp:
    if t.base.kind == tkNamed and t.base.name == "*":
      return "array[" & genType(t.args[1]) & ", " & genType(t.args[0]) & "]"
    # !T / ?T / !?T lower to TuckResult[T] — errors are first-class values
    if t.base.kind == tkNamed and t.base.name in ["!", "?", "!?"] and t.args.len == 1:
      let inner = genType(t.args[0])
      return "TuckResult[" & (if inner == "void": "tuple[]" else: inner) & "]"
    var parts: seq[string]
    for a in t.args: parts.add(genType(a))
    genType(t.base) & "[" & parts.join(", ") & "]"
  of tkFunc:
    # A resolved function reference (`:plus`) carries its real signature.
    # `auto` below is fine for a PARAM (Nim monomorphizes per bake) but is
    # not a type a record field can hold, so a tracked signature emits the
    # concrete proc type instead. Mirrors codegen_odin.nim.
    var ps: seq[string]
    for p in t.params: ps.add(genType(p))
    let r = if t.result != nil and not (t.result.kind == tkNamed and
                                        t.result.name == "void"):
              ": " & genType(t.result)
            else: ""
    "proc(" & ps.join(", ") & ")" & r & " {.closure.}"
  of tkRecord:
    var parts: seq[string]
    for f in t.fields: parts.add(f.name & ": " & genType(f.typ))
    "tuple[" & parts.join(", ") & "]"
  of tkSum:
    var allNoFields = true
    for v in t.variants:
      if v.fields.len > 0: allNoFields = false
    if allNoFields:
      var tags: seq[string]
      for v in t.variants: tags.add(v.name)
      "enum " & tags.join(", ")
    else:
      "ref object"
  else:
    "pointer"
