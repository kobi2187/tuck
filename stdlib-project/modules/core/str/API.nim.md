# core.str — Nim API

## Purpose
Read-only text: a borrowed run of bytes that is known-good UTF-8, plus the everyday operations — split, trim, find, walk the characters. Owned, growable text is `alloc.string`'s `Text`; nothing here allocates, so Nim's `string` and `seq` are deliberately absent from this tier.

## Protocols implemented
`Collection[Rune]` (read-only half: `list`, `count`) and `Gettable[HSlice, TextView]` for slicing by byte span. No `add`/`remove` — a `TextView` borrows, it never grows.

## The API

```nim
type
  TextView* = distinct View[byte]
    ## Borrowed UTF-8. Validated once, at construction, and never re-checked after.
  Pattern* = Rune | TextView | proc (r: Rune): bool
    ## Anything you can search for. `line.split(',')` and `line.split(isSpace)` both work.

func asText*(bytes: View[byte]): TextView
  ## Validates. Raises `Failure` (with a `Where` giving the bad byte offset) on bad UTF-8.
func tryAsText*(bytes: View[byte]): Option[TextView]     ## same, without raising
func asTextUnchecked*(bytes: View[byte]): TextView {.raises: [].}
  ## For bytes you already validated. Named to be greppable.

func bytes*(t: TextView): View[byte]     ## the underlying bytes, no copy
func count*(t: TextView): Count          ## bytes, not characters — see `runeCount`
func runeCount*(t: TextView): Count      ## characters; walks the text, so O(n)
func isEmpty*(t: TextView): bool

iterator list*(t: TextView): Rune                ## the Collection primitive
iterator numbered*(t: TextView): (Index, Rune)   ## byte offset paired with each Rune

func get*(t: TextView, span: HSlice[Index, Index]): Option[TextView]
  ## Absent if either end lands mid-character — you can't accidentally split a Rune.

func find*(t: TextView, what: Pattern): Option[Index]      ## byte offset, or absent
func has*(t: TextView, what: Pattern): bool
func startsWith*(t: TextView, what: Pattern): bool
func endsWith*(t: TextView, what: Pattern): bool

iterator split*(t: TextView, at: Pattern, limit: Count = high(Count)): TextView
  ## Lazy, allocation-free; `limit` caps how many pieces you get.
func trim*(t: TextView, what: Pattern = isSpace): TextView
func trimStart*(t: TextView, what: Pattern = isSpace): TextView
func trimEnd*(t: TextView, what: Pattern = isSpace): TextView
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Str<'a>` | `TextView` | Pairs with `core.slice`'s `View[T]` and with `alloc.string`'s `Text`, so the borrowed/owned split reads the same for bytes and for text. |
| `from_utf8 -> Result` | `asText` / `tryAsText` | The raise/`try` rule replaces `Result`; one of the two names tells you the failure mode. |
| `from_utf8_unchecked` | `asTextUnchecked` | Kept long and ugly on purpose. |
| `chars()` | `list()` | It *is* the Collection primitive, so it gets the protocol's word and inherits `first`/`contains`/`each` for free. |
| `char_indices()` | `numbered()` | Same word `core.iter` and `core.slice` use for "paired with its position". |
| `len()` | `count` + `runeCount` | The Rust name silently meant bytes. Two names, two honest costs. |
| `splitn(n, pat)` | `split(at, limit = n)` | One proc; the rare case is a named option, not a second name to remember. |
| `impl Pattern` trait | `Pattern` type class | A plain Nim `or` type: no concept, no trait impl, and a bare `','` just works. |

## In use

```nim
# todo-cli: pull the +tags out of a task line, with nothing allocated
for word in line.split(' '):
  if word.startsWith('+'):
    word.get(1 .. word.count - 1).ifSome(tag): addTag(tag)

# diff-patch: read a hunk header
let header = raw.trim()
if header.startsWith(asText(atAt)):
  let parts = header.find(' ').orRaise("malformed hunk header")
```

## Vocabulary exceptions
`split`, `trim`, `startsWith`, and `endsWith` are domain verbs kept from ordinary text-processing vocabulary — inventing structural equivalents would obscure rather than clarify, which is exactly the case PROTOCOLS carves out. `asText` is a `to<Format>` verb read backwards (`asX` rather than `toX`) because it borrows rather than deriving a new value; `toBytes`-style names are reserved in this library for conversions that produce something you own.
