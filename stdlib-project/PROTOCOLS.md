# The Protocol Vocabulary — Revised Composition Principles

*Supersedes Design Principle 3 ("small composable interfaces", Go `io.Reader`-modeled) and deepens Principle 4 ("one idiom per cross-cutting concern") from `REPORT.md` Part III. This document governs the Nim expression of the standard library.*

## Why this exists

Two goals drive the whole project, and they pull in the same direction more than they conflict:

1. **Decide which batteries are included.** What functionality ships in the box, and at which tier.
2. **Keep it maintainable.** A standard library's real failure mode isn't missing features — it's accumulating twenty years of inconsistent taste, so that `urllib` and `pathlib` feel like they come from different languages. Python's stdlib is a museum of eras; the report's Part II names this as the single biggest thing separating coherent stdlibs from archaeological ones.

The protocol vocabulary below is the mechanism for (2), and it constrains (1) in a useful way. **A battery only qualifies for inclusion if it can express itself in the shared vocabulary.** A module that needs fifteen novel verb names to describe what it does is telling you it isn't a good fit for a coherent standard library — it's a candidate for the extended ecosystem, where it can have whatever shape it likes. That test is a scoping tool, not just a style rule.

## Principle 3 (revised): procedural, chained, and spoken in a shared vocabulary

**Procedural by default.** Plain mutable objects, ordinary recursion, straightforward control flow. No wrapper types that envelope a value to give it powers (no zippers, no lens/optic machinery, no monadic pipelines). If undo is needed, take a snapshot and keep it — that is what undo means to a person reading the code for the first time.

**Chained, not piped through a stack.** Concatenative composition (Forth) has four genuinely joyful properties: no naming fatigue for intermediates, left-to-right reading order, small single-purpose words, and immediacy — build the pipeline one word at a time and watch it work. The stack is merely the mechanism Forth uses to obtain them, and it is the one part that costs the reader (tracking depth, `dup`/`swap`/`rot`). Nim's UFCS gives all four properties with the stack depth pinned at exactly one:

```nim
text.trim().split(",").map(parseInt).sum()
```

No shuffling words are needed because only one value is ever in play — whatever precedes the dot. This is concatenative *joy* without concatenative *bookkeeping*, and it is plain procedural Nim, not a new paradigm.

**Spoken in a shared vocabulary.** This is the load-bearing part. See below.

## Principle 4 (deepened): one verb per concept, everywhere

Principle 4 previously said "one error mechanism, one formatting mechanism, one comparison mechanism." It now extends to the literal verb: `set` means the same shape of thing in `platform.hal` as in `alloc.map`. Once a user learns a verb once, they can guess its signature in the other 64 modules without reading documentation.

### The structural verbs

| Verb | Shape | Returns |
|---|---|---|
| `get(target, key)` | read one thing by locator | `Option[V]` — never raises for "absent" |
| `set(target, key, value)` | write one thing by locator, absolute | nothing, or `target` for chaining |
| `adjust(target, delta)` | change relative to current value | nothing |
| `add(target, item)` | insert into a collection | `bool` — true if newly added |
| `remove(target, key)` | take one thing out | `Option[V]` — what was removed |
| `has(target, key)` | membership test | `bool` — never raises |
| `find(target, predicate)` | search, may legitimately fail | `Option[V]` |
| `list(target)` | enumerate everything | `iterator` — the one primitive |
| `count(target)` | how many | `int` |
| `clear(target)` | empty it | nothing |
| `copy(target)` | independent duplicate | new value |
| `open(target, mode)` | acquire a resource | handle; raises on hard failure |
| `close(handle)` | release a resource | nothing; idempotent |
| `read(handle, n)` | pull data out | the data |
| `write(handle, data)` | push data in | count written |
| `start(target)` / `stop(target)` | lifecycle of something active | `bool` |
| `send(target, msg)` | hand off a message | nothing |
| `receive(target, timeout)` | await a message | `Option[T]` |
| `wait(target, timeout)` | block until ready | `bool` — met the deadline or not |
| `to<Format>(target)` | derive a new representation | the new value (`toString`, `toJson`, `toBytes`) |

### The three conventions that make the table work

**Argument order is fixed: target, then locator, then value, then options as trailing named arguments.** Knowing this once means `pwm.set("channel1", 80, smooth = true)` is guessable by someone who has only ever used `scores.set("alice", 9)`.

**Absence returns `Option`; failure raises; `try`-prefix opts out of raising.** `get`, `find`, `remove`, and `receive` return `Option` because "not there" is an ordinary outcome, not an error. `open`, `read`, and `write` raise because a failure there means something is actually wrong. Every raising verb has a non-raising sibling (`tryOpen`, `tryRead`) for callers who want to branch instead. The presence or absence of `try` tells you the failure mode without consulting documentation — this is the single rule that lets a casual coder predict error behavior across the entire library.

**Domain verbs keep their own names but obey the argument-order rule.** `encrypt`, `parse`, `compress`, `hash`, `blink` are unambiguous single words; forcing them into `get`/`set` would obscure meaning rather than clarify it. But they still take their subject first and their options last, so even an unfamiliar verb has a guessable shape.

## The protocols

Nine shallow protocols name the recurring clusters. Expressed as Nim `concept`s — structural, so a type qualifies by having the right shape with no inheritance declaration, no vtable, and no runtime cost. This matches "responds to the right words" far better than Go-style explicit interface satisfaction.

```nim
concept Gettable[K, V]
  proc get(x: Self, key: K): Option[V]
  proc has(x: Self, key: K): bool

concept Settable[K, V]
  proc set(x: var Self, key: K, value: V)

concept Collection[T]
  proc list(x: Self): iterator: T      # the sole required primitive
  proc add(x: var Self, item: T): bool
  proc remove(x: var Self, item: T): Option[T]
  proc count(x: Self): int

concept Resource
  proc open(x: var Self): bool
  proc close(x: var Self)
  proc isOpen(x: Self): bool

concept Streamable
  proc read(x: var Self, n: int): seq[byte]
  proc write(x: var Self, data: openArray[byte]): int

concept Lifecycle
  proc start(x: var Self): bool
  proc stop(x: var Self): bool
  proc isRunning(x: Self): bool

concept Adjustable[V]
  proc adjust(x: var Self, delta: V)

concept Messenger[T]
  proc send(x: var Self, msg: T)
  proc receive(x: var Self, timeout: Duration): Option[T]

concept Waitable
  proc wait(x: Self, timeout: Duration): bool
```

**Deliberately flat.** No protocol extends another. A hierarchy would reintroduce exactly the "go read the inheritance chain to understand this type" cost that the vocabulary exists to eliminate.

### Implement one primitive, inherit a bundle

This is the maintainability payoff, borrowed from Ruby's `Enumerable` (which the report's Part II already identifies as a genuinely superior composability model). A type implements `list` and receives everything derivable from it, written once for the entire standard library:

```nim
proc isEmpty[T](c: Collection[T]): bool = c.count() == 0
proc first[T](c: Collection[T]): Option[T] =
  for item in c.list(): return some(item)
  none(T)
proc contains[T](c: Collection[T], item: T): bool =
  for x in c.list():
    if x == item: return true
  false
proc toSeq[T](c: Collection[T]): seq[T] =
  for x in c.list(): result.add(x)
proc each[T](c: Collection[T], action: proc(item: T)) =
  for x in c.list(): action(x)
```

During the three extension rounds, several agents independently reinvented small pieces of exactly this in separate modules. That duplication is the maintainability tax the protocol removes.

### Generic algorithms written once, reused across unrelated tiers

```nim
proc retry(r: var Resource, attempts: int, delay: Duration): bool =
  for i in 1..attempts:
    if r.open(): return true
    sleep(delay)
  false
```

```nim
retry(tcpSocket, 3, 500.ms)       # sys.net
retry(configFile, 3, 100.ms)      # sys.fs
retry(i2cSensor, 3, 10.ms)        # platform.hal — the I2C bus-error retry from round 1
retry(vaultHandle, 3, 1.seconds)  # secrets-vault
```

`embedded-sensor-node`'s I2C retry and `process-supervisor`'s restart backoff were each solved inside their own module during earlier rounds. Under the protocol they are one generic function.

### Discoverability

```nim
echo protocolsOf(led)   # @["Resource", "Gettable", "Settable", "Adjustable"]
```

Very much in the spirit of Rebol's `? word` and Ruby's `respond_to?`: a user can interrogate a value in the same nine-word vocabulary they already know, instead of reading a module's documentation cold.

## Protocol assignments across the library

| Module | Principal type | Protocols |
|---|---|---|
| `alloc.map` | `Table[K,V]` | `Gettable`, `Settable`, `Collection` |
| `alloc.set` | `HashSet[T]` | `Collection` |
| `alloc.vec` | `List[T]` | `Collection`, `Gettable` (by index) |
| `alloc.deque` | `Ring[T]` | `Collection`, `Messenger` (push/pop as send/receive) |
| `alloc.string` | `Text` | `Collection` (of runes), `Streamable` (as builder) |
| `sys.fs` | `File` | `Resource`, `Streamable` |
| `sys.fs` | `Folder` | `Collection` (of entries) |
| `sys.net` | `TcpStream` | `Resource`, `Streamable` |
| `sys.net` | `Listener` | `Resource`, `Collection` (of incoming connections) |
| `sys.process` | `Child` | `Lifecycle`, `Waitable` |
| `sys.sync` | `Channel[T]` | `Messenger` |
| `sys.ble` | `Scanner` | `Lifecycle`, `Collection` (of advertisements) |
| `std.async` | `Task[T]` | `Waitable` |
| `std.net-http` | `Client` | `Resource` |
| `std.encoding` | every codec | `to<Format>` verbs |
| `platform.hal` | `GpioPin` | `Resource`, `Gettable`, `Settable` |
| `platform.hal` | `PwmChannel` | `Resource`, `Settable`, `Adjustable` |
| `platform.rtos` | `Task` | `Lifecycle`, `Waitable` |
| `platform.rtos` | `Queue[T]` | `Messenger` |
| `kv-store-server`'s store | `Store` | `Gettable`, `Settable`, `Collection` |

## Honest gaps in the vocabulary

Two predictions were recorded here *before* the `sys`/`std`/`platform` translation, specifically so they could be checked rather than rationalized afterward. Both have now been tested against all 65 modules. Verdicts:

- **~~`Messenger` may not cover broadcast.~~ RIGHT ABOUT THE PROTOCOL, WRONG ABOUT THE EXAMPLES — and therefore no change made.** `Messenger` genuinely does not express one-to-many delivery; that half held. But neither motivating example needed it. A scope's cancellation reaching every task at once turned out to be **`Waitable`**, not messaging (many tasks `wait`, one `stop` releases them all, and a task arriving late still sees a stopped scope), and `load-tester`'s connection pool is `open`/`close` on a `Resource`. No module across the whole library demanded `publish`/`subscribe`, so per rule 6 below, no `Broadcaster` protocol was added. A prediction that correctly identifies a limit but whose examples dissolve on contact is the best possible outcome: the gap is real, and speculative surface was still avoided.
- **`std.crypto` will strain hardest. CONFIRMED, and worse than predicted — plus the specific remedy guessed wrong.** The module introduced **fifteen domain verbs** (`seal`, `unseal`, `sign`, `verify`, `sameSecret`, `sha256`, `blake3`, `hmacSha256`, `newKey`, `keyFromPassphrase`, `newKeyPair`, `sharedSecret`, `randomBytes`, `toCertificate`, `verifyChain`) — precisely the count the maintainability contract below names as evidence a module belongs in the extended ecosystem. It stays in `std` on the escape clause: each is a single universally understood word taking its subject first and options last, so an unfamiliar reader can still guess the *shape* of `seal(key, plaintext, alongside = ...)` even when the meaning needs documentation. But the predicted "thin `Resource` shell" never appeared — nothing in crypto opens or closes. What emerged instead was `Streamable` on `Digest` and `Collection` on `CertStore`, both incidental, neither on the key types. **`Key` is the deliberate hole in the vocabulary**: no `get`, no `show`, no `$`, so `echo key` does not compile. That is the vocabulary being *correctly* refused where obeying it would be dangerous.

Two further gaps surfaced during translation and are recorded the same way:

- **`Collection` splits cleanly in half, and nothing was done about it.** `core.slice`, `core.array` and `core.str` implement only `list`/`count`, never `add`/`remove` — a fixed-size view has nothing to insert into. Rather than introduce a `ReadOnlyCollection` sibling (more surface, one more thing to learn) this is documented per-module as an honest partial implementation. If a third of the library eventually needs the distinction enforced, that is when to add it.
- **`Gettable`/`Settable` without a locator.** `platform.hal`'s `GpioPin`, `alloc.box`'s `Owned[T]`, `alloc.rc`'s `Shared[T]` and `platform.dsp`'s `MovingAverage` all hold exactly one value, so the key argument would be a constant. They drop it. This is a narrowing of the protocol rather than a violation, and it is recorded in each file rather than quietly done.

**Capabilities were considered and rejected as out of scope.** An earlier draft proposed unforgeable capability tokens for exclusive access (GPIO pin ownership, vault decryption rights). Real capability security requires linear/affine types enforced by the compiler — a language feature, not a library pattern. What remains is the honest, weaker version: **opaque handles with private constructors**. `platform.hal`'s `claim` returns a handle only it can construct, and a second claim returns `none`. Nim improved this slightly over the Rust design — `proc =copy(dst: var GpioPin, src: GpioPin) {.error: "a claimed pin cannot be duplicated — move it".}` makes accidental duplication a compile error with a readable message — but it is still enforced by module privacy plus a plain flag, **not proven**. The defining module can construct another handle internally, `claim` has no synchronization (two cores or an ISR racing need a critical section around it), and a `cast` defeats it entirely. This is documented as "the same guarantee a careful Ruby library gives," and should never be described as more.
- **Capabilities were considered and rejected as out of scope.** An earlier draft proposed unforgeable capability tokens for exclusive access (GPIO pin ownership, vault decryption rights). Real capability security requires linear/affine types enforced by the compiler — a language feature, not a library pattern. What remains is the honest, weaker version: **opaque handles with private constructors**. `platform.hal`'s `claimPin` returns a handle that only it can construct, and a second claim fails. This is enforced by module privacy and a plain check, not proven by the type system; nothing prevents the defining module from constructing another handle internally, and concurrent claims need their own synchronization. That is the same guarantee Ruby or Rebol libraries give in practice, and it should be documented as a convention rather than advertised as a proof.

## The maintainability contract

For anyone extending this library later, the rules that keep it from becoming a museum:

1. **A new module must express its core operations in the structural verbs, or justify each domain verb it introduces.** Needing many novel verbs is evidence the module belongs in the extended ecosystem.
2. **Never invent a synonym.** No `fetch`/`retrieve`/`lookup` when `get` exists. No `put`/`store`/`assign` when `set` exists.
3. **Never vary the argument order.** Target first, options last, always.
4. **Never mix the failure modes.** Absence is `Option`; failure raises; `try` opts out.
5. **Implement the primitive, not the bundle.** Write `list`; do not hand-roll `isEmpty`, `contains`, or `toSeq`.
6. **A protocol is added only when a second module needs it.** One module with an unusual shape is a domain verb set, not a new protocol.
