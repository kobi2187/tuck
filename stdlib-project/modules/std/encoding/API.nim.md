# std.encoding — Nim API

## Purpose
One way to turn values into bytes and back, whichever format you pick. JSON, TOML, CSV, base64, a compact binary packing, streaming XML (and RSS/Atom on top of it) and iCalendar all answer to the same three calls.

## Protocols implemented
`Codec` is a domain concept, but everything that reads a document is a `Collection`: `XmlReader`, `FeedReader` and `IcsReader` each implement `list` and inherit `first`, `each` and `keepIf` for free. Every codec supplies the `to<Format>` verbs PROTOCOLS' assignment table asks for.

## The API

```nim
type
  Encodable* = concept x
    encodeTo(x, var Encoder)
  Decodable* = concept type T
    decodeFrom(var Decoder) is T
  Codec* = concept c
    encode(c, Encodable, var ByteSink)
    decode(c, var ByteSource, typedesc) is Decodable

  Json* = object
    pretty*: bool
  Toml* = object
  Csv* = object
    delimiter*: char
    hasHeader*: bool
  Binary* = object
    endian*: Endian

# The everyday surface: to<Format> and its inverse, for documents small enough to hold.
proc toJson*[T](value: T; pretty = false): Text
proc fromJson*[T](text: TextView; as: typedesc[T]): T      ## raises `Failure` with a `Where`
proc tryFromJson*[T](text: TextView; as: typedesc[T]): Option[T]
proc toToml*[T](value: T): Text
proc fromToml*[T](text: TextView; as: typedesc[T]): T

# The primitive: streaming, so a 2 GB file never has to fit in memory.
proc encode*[T](c: Codec; value: T; into: var ByteSink)
proc decode*[T](c: Codec; source: var ByteSource; as: typedesc[T]): T
proc tryDecode*[T](c: Codec; source: var ByteSource; as: typedesc[T]): Option[T]
proc codecFor*(extOrMime: TextView): Option[Codec]

proc toDynamic*(c: Codec; source: var ByteSource): Dynamic
  ## JSON and TOML only. Decodes with no target type at all, preserving the
  ## document's own shape as `std.reflect`'s `Dynamic` tree — what a schema
  ## validator needs when neither side is known at compile time.

proc toBase64*(bytes: View[byte]): Text
proc fromBase64*(text: TextView): List[byte]               ## raises; `tryFromBase64` doesn't
# toBase32 / toBase16 mirror the pair exactly.

# XML — streaming only. There is no DTD switch, because there is no DTD code.
type XmlReader* = object
type XmlEvent* = object
  case kind*: XmlKind
  of Open: name*: TextView; attrs*: openArray[(TextView, TextView)]
  of Chars: text*: TextView
  of Close: closing*: TextView
proc newXmlReader*(source: var ByteSource): XmlReader
iterator list*(x: var XmlReader): XmlEvent                 ## the Collection primitive

type FeedReader* = object                                  ## RSS 2.0 and Atom, on top of XmlReader
proc newFeedReader*(source: var ByteSource): FeedReader
iterator list*(f: var FeedReader): FeedItem

# iCalendar
type IcsReader* = object
proc newIcsReader*(source: var ByteSource): IcsReader
iterator list*(i: var IcsReader): IcsPart                  ## VEvent | VZone | VAlarm
proc write*(w: var IcsWriter; ev: VEvent; repeats = none(Recurrence))
  ## The structural `write` verb. `repeats` is rendered to RRULE text by
  ## `std.chrono.toRrule`, never re-derived here.
```

`VEvent.rrule` stays a raw `Option[Text]`. Turning it into occurrences is `std.chrono.toRecurrence`'s job — this module has no timezone database and should not grow one to serve one format.

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Encode` / `Decode` traits | `Encodable` / `Decodable` | `-able` matches `Showable`, `Inspectable`, `Listable` — the reader already knows the suffix means "responds to the right word". |
| `Codec::encode(v, w)` | `toJson` / `encode` | The two-line case gets the `to<Format>` verb; the streaming case keeps `encode`. Same contract, two comfort levels. |
| `decode_value` | `toDynamic` | Another `to<Format>` verb, and it names the type you get instead of the type you didn't supply. |
| `XmlReader::next -> Option<Event>` | `iterator list` | The reader becomes a `Collection`, so `first`, `each` and early `break` all work without a hand-rolled loop. |
| `Event::Start/Text/End` | `Open/Chars/Close` | `Text` is `alloc.string`'s type name; reusing it for "character data" would be the worst collision in the module. |
| `FeedReader::items()` | `iterator list` | Same primitive as every other reader, so `podcast-subscriber`'s early stop is a plain `break`. |
| `IcsWriter::write_event` | `write(w, ev, repeats =)` | The structural write verb with options last. |
| `base::encode64` | `toBase64` | Reads as a conversion; `fromBase64`/`tryFromBase64` carry the failure mode. |

## In use

```nim
# podcast-subscriber: stop the moment a known GUID shows up — no whole-feed buffering
var feed = newFeedReader(response.body)
for item in feed.list():
  if known.has(item.guid): break
  queue.add(item.enclosureUrl)

# config-schema-validator: two trees, neither known at compile time
let config = Toml().toDynamic(configFile)
let schema = Json().toDynamic(schemaFile)
validate(config, schema, path = newText(capacity = 128))

# math-toolkit-cli: the price column decodes as Decimal, because the caller said so
for row in Csv(hasHeader = true).decode(file, Row):
  prices.add(row.price)          # Decimal, never float — CSV never guesses
```

## Vocabulary exceptions
`encode`, `decode` and the `to<Format>` family are the module's domain verbs, and PROTOCOLS names them explicitly. `list` on three different readers is the enumerate verb applied to something that streams rather than something that stores — the same widening `core.error` already takes for walking a cause chain.

**CSV requires a target type.** `decode(Csv(), src, Row)` parses each column against the field's declared type; there is no untyped path, because `"007"` guessed as `7` is silent corruption and `doc-convert-tester`'s round-trip harness is built to catch exactly that. This is a documented divergence from the one-calling-convention rule, justified because CSV alone among these formats has no type system of its own to decode against.

**Recorded exclusions.** *YAML* fails the inclusion policy's second test: its ambiguity (unquoted `no` becoming `false`) is load-bearing to the specification, with no safe subset to carve out the way XML's DTD path could simply not be implemented. *Unified diff* fails the first test: it is one algorithm's output, not a target you would serialize arbitrary data into. Both stay in the extended ecosystem, on the record.
