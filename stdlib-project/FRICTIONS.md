# Frictions found translating the stdlib design into Tuck

Every item here was hit while writing real `.tuck` code for
`stdlib-project`'s modules and reproduced against the compiler. Error text
is quoted verbatim, not paraphrased. Nothing here is a complaint about the
design — these are the places where a competent author following the docs
gets stopped, or gets an error about something other than what they did
wrong.

Ordered by how much they cost, not by severity of the underlying bug.

---

## 1. Generic `fnsig` does not parse

```tuck
fnsig Mapper[T, U] = {x: T} -> U
```
```
[Parse Error] at line 1, column 8:
  Expected `Assign` here, found `[`
```

**Cost: blocks every higher-order generic API.** `map`/`filter`/`reduce`
over `Seq[T]` all need a `fnsig`-typed parameter, and `fn`/`type` both take
type parameters — so the absence reads as an oversight rather than a rule.

**The dangerous part** is the workaround that *appears* to work:

```tuck
fnsig Mapper = {x: T} -> U     # typechecks! but T and U are Unknown
```

Gradual typing reads the unbound `T`/`U` as `Unknown`, so this passes
`tuck ch` while checking nothing — exactly the trap `LANGUAGE-OVERVIEW.md`
§0 warns about ("sketch code and a destroyed parse tree both read
`Unknown`"). An author who tries the obvious spelling, hits the parse
error, and then "fixes" it this way has silently disabled type checking on
their callback.

**Suggested:** support `fnsig Name[T, U] = ...`. Failing that, reject bare
unbound type names in a `fnsig` so the workaround can't look green.

---

## 2. Generic `actor` does not parse

```tuck
actor Box[T] [queue: 4]:
```
```
[Parse Error] at line 1, column 14:
  Expected `Colon` here, found `[`
```

The `[queue: N]` slot is the only bracket an actor declaration accepts.

**Cost: `std.queue`'s `DurableQueue[T]` cannot be written**, and any other
service actor generic over its payload. Workarounds are one declared actor
per payload type, or carrying payloads pre-encoded as bytes.

**Genuinely unclear whether this is a bug**, and worth a ruling either way:
an actor is a compile-time singleton with no construction step, so "one
instance, generic over `T`" may not be meaningful — nothing ever supplies
`T` the way a call site does for a generic `fn`. If it's deliberate, the
error should say so; right now it reads as a parser gap.

---

## 3. Storing into a `fnsig` slot is not signature-checked

```tuck
fnsig Predicate = {x: int} -> bool
type Query = {items: Seq[int], test: Predicate}

fn wrongShape({a: str}) -> str: ...

let q1 = {items: [1,2,3], test: :wrongShape} Query      # accepted
let q2 = {items: [1,2,3]} bake {test: :wrongShape}      # accepted
```

Both typecheck `OK`. A `{a: str} -> str` function sits in a
`{x: int} -> bool` slot with no complaint.

`tests/suites/typecheck.nim:1805` covers the *other* direction — a call
*through* a fnsig slot checks arity — so the gap is specifically on the
store.

**Cost: `bake`'s core promise is unenforced.** The feature's whole contract
is "fills a slot whose signature the record declares"; without the check,
the mismatch surfaces later as a backend type error, or not at all.

---

## 4. Direct recursive sum types fail in the *backend*, not the checker

```tuck
type Expr:
  | Lit({v: int})
  | Add({left: Expr, right: Expr})
```

`tuck ch` → `OK`. `tuck b` →
```
p_tree_direct.nim(4, 6) Error: illegal recursion in type 'tuck_Expr'
tuck: nim compilation failed
```

The author gets a Nim error, about generated code they never wrote, naming
a mangled type (`tuck_Expr`), at a line number in a file they don't have
open.

**This is not a language gap** — recursion through a `Seq` works fine and is
the right shape anyway:

```tuck
| JArr({items: Seq[Json]})     # typechecks and builds
```

A value type's size must be finite; `{left: Expr, right: Expr}` demands
`sizeof(Expr) ≥ 2·sizeof(Expr)`. `Seq` supplies the size break without the
sharing a `ref` would introduce.

**Cost: purely diagnostic, and cheap to fix.** Detect direct
self-containment in a sum type or record at check time and say so in Tuck's
own terms — naming the field, and pointing at `Seq[T]` as the fix.

---

## 5. `pending` is reserved and cannot be a field name

```tuck
type Q = {pending: Seq[FetchResult]}
```
```
[Parse Error] at line 1, column 11:
  Expected field name in record definition
```

Hit while writing `std.db`'s cursor design, where `pending` is the natural
name for "results not yet collected". Renamed to `fetched`.

**Cost: small but confusing.** The message says "expected field name" while
pointing *at* something that looks exactly like a field name. It never
mentions that the word is reserved or why.

**Suggested:** name the collision — "`pending` is a reserved word (the
`pending:` block); choose another field name."

---

## 5b. `error` is reserved and cannot be a function name

```tuck
pending:
  fn error({sink: LogSink, msg: str}) -> void [io]
```
```
[Parse Error] at line 25, column 6:
  Expected function name in pending declaration
```

Same shape as #5 (`pending` as a field name): the word is reserved — here
because `[error: FsError]` is an effect attribute — but the message says
"expected function name" while pointing at what looks exactly like one.

**Cost: `error` is the natural name for a log level's verb.** Every logging
library has `log.error(...)`; `std.log` had to use `fail` instead. The same
collision will hit any module wanting `error` as a verb.

Note `LANGUAGE-OVERVIEW.md` §3 already documents the reserved-in-brackets
list (`error`, `stack`, `queue`, `align`, `priority`, `volatile`, ~13 more)
in the context of `Box[error]` failing to parse as a *type argument* — this
is the same word list biting in an identifier position, so the fix is
likely shared: say which word is reserved and why.

## 5c. `when` is reserved and cannot be a field name

```tuck
type ZonedTime = {when: DateTime, zone: Zone, offsetSec: i32}
```

Same failure as #5/#5b — `when` is the `when TARGET == "..."` conditional.
Renamed to `moment`.

**Three instances of one problem** (`pending`, `error`, `when`), all hit
while writing ordinary stdlib types, all reported as "expected a field
name / function name" while pointing at one. A reserved word used in an
identifier position should say so by name. The full list is already
documented in `LANGUAGE-OVERVIEW.md` §3 for the bracket case; the parser
just doesn't consult it when producing this message.

## 6. `satisfies` on a primitive — correct refusal, unhelpful message

```tuck
satisfies int: Hashable
```
```
Conformance Error: `int satisfies ...` names 'int', which is not a
declared object in scope
```

**Not a bug** — `satisfies` matches objects (and possibly named types) to
interfaces; primitives are deliberately excluded.

**Cost: the message misdiagnoses.** "not a declared object in scope"
suggests a missing declaration or an import problem, so the reader's next
move is to go looking for one. Saying "primitives cannot satisfy
interfaces" would end the search immediately.

Left a real design question downstream: `Table[str, V]` needs its key
hashed, and can't get it from an interface. Likely answer is a `fnsig` hash
slot (composes with `bake`, no language change) — noted in
`modules/alloc/map/API.tuck.md`.

---

## 7. An opaque handle cannot be an actor field — good error, real constraint

```tuck
actor Db [queue: 32]:
  conn: Sqlite3        # opaque extern handle
```
```
Type Error: Sqlite3 is a pointer — it may only appear in an extern
signature, not an actor field (cross into safe Tuck with a converter
such as toStr)
```

**The message is genuinely good** — it names the type, the rule, the
position, and a way forward. Recorded as the example to imitate, not to
fix.

**The constraint is real and shapes `std.db`:** an actor-shaped database
service cannot hold its connection between messages. The workable answer is
a safe key (an `int` slot id) with the handle living in the impl module —
meaning the "driver" includes a little backend-language code, not pure
Tuck.

---

## 8. `Seq` copies across call boundaries (open, not yet a decision)

`fn push({items: Seq[int], value: int}) -> Seq[int]` emits as:

```nim
proc tuck_addOne*(items: seq[int], value: int): seq[int] =
```

Plain value in, plain value out — no `sink`, no `var`. So an append loop is
O(n²) today, across `alloc.vec`, `alloc.string`, `alloc.deque`, `alloc.map`
and `alloc.set` alike.

The call-site spelling is already right — `xs ..push {value: 4}` lowers to
`xs = tuck_push(xs, 4)` — so **this is a lowering question, not an API
one.** How `Seq` crosses a boundary is Tuck's own call to make; recorded
here so it's decided deliberately rather than inherited. `benches/` exists
for measuring it.

---

## 9. Full-mailbox behaviour is unspecified (design gap, not a bug)

`send` is fire-and-forget with no return value, and `[queue: N]` is a
compile-time bound — so a mailbox can fill. **What happens then is stated
nowhere**: not in `tuck-spec.md` §9.1, not in `LANGUAGE-OVERVIEW.md` §10,
not in any example. Does `send` block the sender, drop the message, or
raise?

The spec says only that "queue size is a compile-time constant — the ring
buffer is sized to it exactly, so a full mailbox is a fixed, known
capacity, not an unbounded allocation," which describes the *sizing*, not
the *policy*.

**Cost: every actor-shaped stdlib module needs this answer.**
`sys.window`'s input events, `std.queue`'s pushes, `sys.audio`'s control
messages, and `std.db`'s queries are all "what if the consumer is slower
than the producer" cases. The Nim design had three distinct spellings for
the choice (`send` blocks = backpressure, `trySend` returns false,
`Handoff.trySend` never blocks or allocates); Tuck has one verb and no
documented policy.

Note this is *not* the same as the reply question already resolved in
`TUCK-TRANSLATION.md` — that was "how does a value come back"; this is
"what happens to a message that can't fit."

## Pattern worth noting

Four of these (1, 4, 5, 6) share a shape: **the compiler is right to
refuse, but the message describes the parser's or backend's problem rather
than the author's.** #7 shows the house standard when it goes well — names
the type, the rule, the position, and the way out. Bringing 1/4/5/6 up to
that bar is a smaller job than fixing the underlying features, and would
remove most of the friction recorded here.
