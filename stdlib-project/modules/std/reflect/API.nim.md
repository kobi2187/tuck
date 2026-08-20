# std.reflect — Nim API

## Purpose
Looking at a value's shape when you did not know that shape while writing the code — a config file checked against a schema loaded at run time, a debugger, a generic pretty-printer. Opt-in per type, so nothing pays for it unless it asks.

## Protocols implemented
`Gettable[string, Any]` and `Settable[string, Any]` on `Any` (fields by name), `Collection[Any]` on `DynValue` (walk a tree). This is the tier's clearest case of the protocols paying off: a reflected value answers the same four verbs as a `Table`.

## The API

```nim
type
  Any* = object
    ## A value plus its type description. Borrowed — it does not own what it points at.
  Shape* = enum
    Number, Text, Truth, Record, Listing, Mapping, Absent
  DynValue* = object
    ## A tree that owns itself, built by decoding a document whose shape was
    ## unknown at compile time. This is what config files become.
    case shape*: Shape
    of Record, Mapping: fields*: Table[Text, DynValue]
    of Listing: items*: List[DynValue]
    of Number: number*: float
    of Text: text*: Text
    of Truth: truth*: bool
    of Absent: discard

macro reflectable*(T: typedesc)
  ## Opt in. Generates the description for `T` at compile time. A type that never
  ## says this has no reflection data in the binary at all — the cost is chosen,
  ## not ambient, which is the whole difference from Java and C#.

proc toAny*[T: reflectable](value: var T): Any
proc shape*(a: Any): Shape
proc typeName*(a: Any): string
proc get*(a: Any; field: string): Option[Any]
proc set*(a: var Any; field: string; value: Any)     ## raises on type mismatch
proc has*(a: Any; field: string): bool
iterator list*(a: Any): (string, Any)                 ## fields, in declaration order
proc to*[T](a: Any): Option[T]                        ## back to a real typed value

proc get*(v: DynValue; path: string): Option[DynValue]
  ## Dotted path: `cfg.get("server.tls.certPath")`. The one call a config tool makes.
iterator list*(v: DynValue): (string, DynValue)
proc walk*(v: DynValue; visit: proc (where: Where; node: DynValue))
  ## Depth-first, carrying core.error's Where so a violation can say exactly
  ## which line and which field path it was found at.
proc show*(v: DynValue): Text
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Reflect` trait + `#[derive(Reflect)]` | `reflectable(T)` macro | one word, and it reads as the permission it grants |
| `TypeInfo` / `ValueRef` | `Any` | the familiar name for "a value whose type I do not know statically" |
| `Kind` / `TypeId` | `Shape` | "kind" is overloaded (Nim uses it for variant tags); shape is what you are asking about |
| `get_field` / `set_field` | `get` / `set` | the structural verbs; a reflected record is a keyed lookup like any other |
| `fields()` | `list` | `Collection`'s primitive, so `count`, `first` and `toSeq` come free |
| `DynValue::Map` | `DynValue` with `shape` | one type with a variant tag rather than a name per case — Nim's object variants are the natural fit |
| `visit_recursive(visitor)` | `walk(v, visit)` | shorter, and `Where` in the callback is what makes error reporting precise |

## In use

```nim
# config-schema-validator: both the config AND the schema arrive at run time,
# so there is no compile-time type to reflect on — this is DynValue's whole reason
let cfg = Toml.decodeValue(readFile("app.toml"))
for rule in schema.rules:
  case cfg.get(rule.path)
  of Some(node):
    if node.shape != rule.expect:
      violations.add Violation(at: node.where, msg: "expected " & $rule.expect)
  of None:
    if rule.required: violations.add Violation(at: rule.path.asWhere, msg: "missing")

# doc-convert-tester: one generic printer for every format's decoded output
echo decoded.show()
```

## Vocabulary exceptions
None. This module is the vocabulary's best case — `get`, `set`, `has`, `list` on `Any` mean exactly what they mean on `alloc.Table`, and a reader who has used one has already learned the other. `walk` is the single domain verb, and only because `list` is depth-one by contract while `walk` is recursive; conflating them would make `count` ambiguous.

## Honest limits
`get(v, "server.tls.certPath")` parses its path string on every call. A `Path` type compiled once would be faster for a validator checking thousands of documents, and is deliberately not added — no app in the set has needed it, and PROTOCOLS' rule 6 says a second demand, not a first guess, justifies new surface. Also: JSON-Schema's specific vocabulary (`anyOf`, `$ref`, `additionalProperties`) is **not** in this module or `std.encoding`. `DynValue` gives a schema tool the tree to walk; the schema language itself belongs to the extended ecosystem.
