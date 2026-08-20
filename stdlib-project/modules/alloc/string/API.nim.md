# alloc.string — Nim API

**Purpose**
`Text` — an owned, growable, always-valid-UTF-8 string you can build up piece by piece. The heap-backed companion to `core.str`'s borrowed `TextSlice`.

**Protocols implemented**
`Collection` (of runes) and `Streamable` (as a builder), per PROTOCOLS' assignment table.

## The API

```nim
type Text* = object   ## owned, valid UTF-8, allocator-aware, and its own builder

proc newText*(memory = defaultMemory()): Text
proc newText*(capacity: int; memory = defaultMemory()): Text
  ## Reserve when you know roughly how long the result is.
proc toText*(s: TextSlice; memory = defaultMemory()): Text     ## copies; raises OutOfMemory
proc tryToText*(s: TextSlice; memory = defaultMemory()): Option[Text]

proc add*(t: var Text; c: Rune): bool {.discardable.}
proc add*(t: var Text; s: TextSlice): bool {.discardable.}     ## the everyday append
proc tryAdd*(t: var Text; s: TextSlice): bool                  ## false instead of raising
proc write*(t: var Text; data: openArray[byte]): int
  ## Streamable. Appends raw bytes and validates the boundary once. Raises on invalid UTF-8.
proc read*(t: var Text; n: int): seq[byte]                     ## Streamable, for symmetry
proc slice*(t: Text): TextSlice                                ## zero-copy view for all of core.str
proc count*(t: Text): int                                      ## runes, not bytes
proc bytes*(t: Text): int                                      ## bytes, when you actually mean bytes
proc clear*(t: var Text)
proc truncate*(t: var Text; bytes: int)
  ## Cuts back to a byte length. Raises if that isn't a rune boundary — validity is an invariant here,
  ## not something you remember to check.
proc mark*(t: Text): int                                       ## save a length, push, recurse, truncate back
iterator list*(t: Text): Rune                                  ## the sole Collection primitive
proc memory*(t: Text): Memory

# Secrets — composition, not a forked type
type SecretText* = Secret[Text]
proc newSecretText*(memory: SecureMemory): SecretText
```

Everything derivable — `isEmpty`, `first`, `contains`, `each` — arrives via `Collection`. Splitting, trimming, and searching live once in `core.str` and work on `t.slice()`; this module deliberately does not restate them.

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `String` | `Text` | PROTOCOLS' table. Also dodges a head-on collision with Nim's built-in `string` |
| `&str` (core.str) | `TextSlice` | obviously the borrowed sibling of `Text`; nobody has to learn what "str" abbreviates |
| `StringBuilder` | *gone* — `Text` is its own builder | PROTOCOLS makes `Text` `Streamable`; one type, and casual coders never meet a second one |
| `push` / `push_str` | `add` (overloaded) | one verb, two overloads. Nim picks the right one; you never pick a suffix |
| `from_str` / `from_str_in` | `toText(slice, memory =)` | a `to<Format>` verb, matching the whole library |
| `as_str` | `slice` | short, and names the relationship rather than the encoding |
| `len` (bytes!) | `count` (runes) / `bytes` (bytes) | the single nastiest silent bug in string APIs, split into two words you cannot confuse |
| `SecretString` (rejected) | `Secret[Text]` | composition, exactly as the Rust design decided — the Nim alias just makes it typeable |

## In use — secrets-vault

```nim
let vaultMem = newSecureMemory()                     # zero-on-free, page-locked where the OS allows
var pass = newSecretText(vaultMem)
pass.use do (t: var Text):
  t.add(prompt("master passphrase: ", echo = false))  # plaintext never leaves this block
  key = argon2id(t.slice(), salt)
# `pass` is zeroed by =destroy at end of scope. `$pass` prints "<secret>". There is no `get`.
```

And config-schema-validator's field paths, one buffer for the whole traversal:

```nim
var path = newText(capacity = 128)
proc visit(node: Node) =
  let here = path.mark()
  path.add(node.name); path.add(".")
  for child in node.children: visit(child)
  path.truncate(here)          # pop a segment; no allocation on the way back out
```

## Vocabulary exceptions

- **`Text` is both `Collection` and `Streamable`, and `write` means append.** PROTOCOLS assigns both, so `write(t, bytes)` is the builder path and `list(t)` is the reading path on one type. That is a wider type than the rest of the tier, taken on the table's authority; the payoff is that `alloc.fmt`, `sys.io`, and `std.encoding` can all write into a `Text` with the verb they already use.
- **`read` on a `Text` is present for `Streamable` completeness and is rarely what you want.** Use `slice()` and `core.str`.
- **`mark` / `truncate` deliberately echo `alloc.allocator`'s `Arena`.** Same push/checkpoint/rewind shape, same two words, in two modules — that's the vocabulary working, not a coincidence.
- **`Secret[Text]` has no `Deref`.** Nim has none to give, which turns out to be a feature: the Rust design's own Open Question was that `Deref` lets a borrowed `&str` escape into a log line. `use()` scoping closes that hole by construction, and `Text` never implements `$` on a `Secret`.
