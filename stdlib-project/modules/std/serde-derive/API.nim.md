# std.serde-derive — Nim API

## Purpose
Generate a type's encoding and decoding code at compile time, so a program that knows its shapes in advance pays nothing at run time — no reflection tables, no field-name lookups, no allocation it did not ask for.

## Protocols implemented
None of the nine — this is a code generator, not a value. What it *generates* satisfies `std.encoding`'s `Encodable`/`Decodable`, which is the point: after the macro runs, the type plugs into every codec through the same two procs a hand-written implementation would provide.

## The API

```nim
macro serializable*(T: typedesc)
  ## Generates `encodeTo` and `decodeFrom` for `T` and everything it contains.
  ## Works with any codec in std.encoding — the generated code targets the
  ## Encoder/Decoder concepts, not one specific format.

type Task = object
  id: Uuid
  title: Text
  done: bool
  due {.rename: "due_date".}: Option[Instant]
  notes {.skipIfEmpty.}: Text
  internal {.ignore.}: int

serializable Task

# What you get, for every format, with no further work:
proc encodeTo*[T: serializable](value: T; e: var Encoder)
proc decodeFrom*[T: serializable](d: var Decoder): T   ## raises Failure with a Where
proc tryDecodeFrom*[T: serializable](d: var Decoder): Option[T]
```

Field pragmas, all optional:

```nim
{.rename: "wire_name".}   ## the name on the wire differs from the name in code
{.ignore.}                ## never encoded, never expected when decoding
{.skipIfEmpty.}           ## omit when empty/zero/none — keeps documents small
{.default: expr.}         ## what to use when the field is absent while decoding
{.flatten.}               ## splice a nested object's fields into the parent
```

```nim
macro serializableAs*(T: typedesc; naming: static Naming)
  ## `serializableAs(Task, SnakeCase)` — one declaration instead of a `rename`
  ## pragma on every field. Naming is one of AsWritten, SnakeCase, KebabCase, CamelCase.
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `#[derive(Serialize, Deserialize)]` | `serializable T` | one word covers both directions; nobody derives one without the other in practice |
| `#[serde(rename = "x")]` | `{.rename: "x".}` | Nim's own pragma syntax — a Nim reader already knows this shape |
| `#[serde(skip)]` | `{.ignore.}` | "skip" reads as "skip this time"; ignore is permanent, which is what it means |
| `#[serde(skip_serializing_if = "Option::is_none")]` | `{.skipIfEmpty.}` | the Rust version makes you name a predicate function to express the single case everyone wants |
| `#[serde(rename_all = "snake_case")]` | `serializableAs(T, SnakeCase)` | a typed enum instead of a magic string, so a typo is a compile error |
| `Serializer` / `Deserializer` traits | `Encoder` / `Decoder` concepts (in `std.encoding`) | matches the words `std.encoding` already uses; two vocabularies for one idea was the confusing part |

## Why this is a natural fit in Nim

Nim's macros operate on the typed AST, so `serializable` reads a real object definition — field names, types, pragmas, inheritance — and emits ordinary procs the compiler then optimizes like any hand-written code. There is no build script, no separate derive crate, no procedural-macro compilation step: the macro is a normal proc that runs at compile time in the same file. This is the one place where the Nim translation is straightforwardly *better* than the Rust design it came from rather than merely equivalent.

## In use

```nim
# todo-cli: one declaration, and the type now speaks JSON (export) and
# binary (the local database) through the same codec interface
serializable Task
file.write(Json.encode(tasks))
let restored = Binary.decode[:List[Task]](db.read())

# kv-store-server: WAL records, where the binary codec's speed is the point
serializableAs(WalRecord, SnakeCase)
wal.write(Binary.encode(record))
wal.syncData()
```

## Vocabulary exceptions
The macro name is a domain word, as every code generator's must be. The generated procs (`encodeTo`, `decodeFrom`) are `std.encoding`'s names, not new ones — which is the rule working: a hand-written codec and a generated one are indistinguishable to a caller.

## Honest limits
This is the compile-time half of a pair. When the shape is *not* known until run time — `config-schema-validator` loads both its config and its schema from disk — this macro has nothing to offer and `std.reflect`'s `DynValue` is the answer instead. The two are deliberately separate modules with no shared machinery, because merging them would mean every program that just wants a fast JSON round-trip carries the dynamic path's cost. Choosing between them is the one piece of genuine judgment this pair asks of a user, and the rule is short: *shape known when you compile it* → `serializable`; *shape arrives with the data* → `std.reflect`.
