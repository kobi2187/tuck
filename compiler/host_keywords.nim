# compiler/host_keywords.nim
#
# WORDS NO PARAMETER OR FIELD MAY BE NAMED, because some backend reserves them.
#
# A parameter and a field are the identifiers mangle.nim deliberately leaves
# alone. Its charter says locals and params "are not global, cannot collide" —
# true of other declarations, FALSE of the target language's own keywords.
# alloc.string found the parameter half: a parameter named `with` emitted
# `string tuck_replace(string t, string what, string with)` and dmd answered
# "found `with` when expecting `)`".
#
# The FIELD half went unguarded until 2026-09-12: `type T:` with a field `out`
# emitted `out*: string`, which nim and dmd both refuse (odin happens to
# accept that particular word, which is exactly why the list is a union). The
# two belong together — a payload field binds to a parameter BY NAME, so
# guarding only one leaves a field you can declare and never pass.
#
# REJECTED, NOT RENAMED. Mangling the parameter would change every emitted
# signature for a name the author picked and can see, to work around a word
# they cannot see; and Tuck's rule is that the compiler rejects faults rather
# than quietly transforming them. The author picks another name, once, and the
# emitted code keeps saying what the source says.
#
# THE LIST IS MEASURED, NOT COPIED. Each candidate was compiled as an actual
# parameter name against dmd, nim and odin; only the ones a host really
# refuses are here. That matters in both directions:
#
#   - `body` is a D keyword in every reference list and dmd ACCEPTS it (it is
#     contextual since 2.101). Copying the reference list would have rejected
#     examples/14-task.tuck, which has used `body` all along.
#   - `string` is not a D keyword at all — it is an alias in object.d — so a
#     parameter may be called that, even though a MODULE may not (which is a
#     different collision, see codegen_d_emit.DShadowingModuleNames).
#
# Counts at the time of measurement: D refuses 99, Nim 71, Odin 40; the union
# is 154. Re-measure rather than edit by hand if a backend's version moves.
import sets

const HostKeywords* = [
  "__gshared", "__parameters", "__traits", "__vector", "abstract",
  "addr", "alias", "align", "and", "as", "asm", "assert", "auto",
  "auto_cast", "bind", "bit_set", "block", "bool", "break", "byte",
  "case", "cast", "catch", "cent", "char", "class", "concept", "const",
  "context", "continue", "converter", "dchar", "debug", "default",
  "defer", "delegate", "deprecated", "discard", "distinct", "div", "do",
  "double", "dynamic", "elif", "else", "end", "enum", "except", "export",
  "extern", "fallthrough", "false", "final", "finally", "float", "for",
  "foreach", "foreach_reverse", "foreign", "from", "func", "function",
  "goto", "idouble", "if", "ifloat", "immutable", "import", "in",
  "include", "inout", "int", "interface", "invariant", "ireal", "is",
  "isnot", "iterator", "lazy", "let", "long", "macro", "map", "matrix",
  "method", "mixin", "mod", "module", "new", "nil", "not", "not_in",
  "nothrow", "notin", "null", "object", "of", "or", "or_break",
  "or_continue", "or_else", "or_return", "out", "override", "package",
  "pragma", "private", "proc", "protected", "ptr", "public", "pure",
  "raise", "real", "ref", "return", "scope", "shared", "shl", "short",
  "shr", "static", "struct", "super", "switch", "synchronized",
  "template", "this", "throw", "transmute", "true", "try", "tuple",
  "type", "typeid", "typeof", "ubyte", "ucent", "uint", "ulong", "union",
  "unittest", "ushort", "using", "var", "version", "void", "wchar",
  "when", "where", "while", "with", "xor", "yield"
]

proc isHostKeyword*(name: string): bool =
  name in HostKeywords
