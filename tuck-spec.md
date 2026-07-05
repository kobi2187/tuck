# The Tuck Language — Canonical Specification
### Version 0.1 — Working Draft

---

## Part 1: Philosophy

Tuck is a systems-capable language designed primarily for embedded and constrained
environments, suitable for general application development. It targets the gap where
C is fifty years old, C++ brings hidden costs, and Rust's ownership model fights
against embedded patterns.

The goal is not academic novelty. The goal is **maintainability, obviousness, and
fearless refactoring**. Programs always grow. Debugging is hard and slow. Therefore
the language must make everything explicit, locatable, and auditable.

Tuck achieves this through a single radical constraint:

> **Every piece of data flows through the system as a named struct.**

By restricting the shape of code, Tuck frees the programmer to focus entirely on
the shape of data. The result is a language that feels like a catalog of tiny,
obvious, unbreakable blocks snapping together.

### The Three Answers

For every major concern, Tuck has exactly one answer. There are no two ways to do
any of these things:

| Concern | Answer |
|---|---|
| State | Sum types with sealed transitions |
| Errors | `!T` propagation with `or` |
| Absence | `?T` with `or` |
| Side effects | Effect markers `[io, no_alloc, ...]` |
| Shared mutable state | Actors with typed message queues |
| Short async operations | Tasks — `[io]` functions yield implicitly |
| App-wide signals | One `registry`, one handler per event |
| Hardware access | Register declarations, units, packed types |
| Correctness | Decision tables, transition graphs, invariant asserts |
| Composition | Domain files, mixins, manager objects |

---

## Part 2: The Universal Shape

### 2.1 Named Structs Are the Only Container

In Lisp, everything is a list. In Forth, everything is a stack. In Tuck, everything
is a named struct. A single integer is conceptually `{value: 5}`. The compiler
allows syntactic sugar (`5.ms`) but semantically it is always a struct. The
backend optimizes the wrapping away completely.

```tuck
# Data flows through postfix chains
let request = {url: "example.com", timeout: 5.ms}
let response = request fetch parse episodes

# Bind to a variable to branch
var feed = {url: "..."} fetch
if feed.hasNew:
  feed.episodes process
else:
  feed.metadata log
```

### 2.2 No Destructuring

You do not unpack a struct into local variables. If you need a field, you access
it via `.fieldName` on the flowing struct or the bound variable. The struct flows
as a whole.

### 2.3 Postfix Invocation vs. Mutation

Two distinct surface forms, keeping pure calls and stateful mutation separate:

- **whitespace** — implicit function invocation. The previous struct is passed as
  the single payload to the next function.
- **`..` (DotDot) — Mutation/builder.** Modifies a bound `var` in place and
  returns it for further chaining.

```tuck
# Functional pipeline — immutable, each step receives the previous struct
let result = {config} connect query

# Builder pattern — stateful assembly on a var
var server = ServerConfig {}
server ..port {8080} ..timeout {30.seconds} ..start
```

Mutating a struct requires using `..` on a `var`. The compiler rejects `..` on
`let` bindings. This friction is intentional — it encourages extraction and keeps
functions tiny.

### 2.4 Field Access Auto-Wrap

Accessing a single field wraps it automatically into a single-field struct so
function uniformity is preserved:

```tuck
player.volume normalize   # volume: int → {value: int} → passed to normalize
```

This is a compile-time rewrite. Zero runtime cost.

### 2.5 Subset Matching

If a flowing struct contains more fields than a function requires, the extra fields
are silently ignored. The function receives exactly the subset it declared:

```tuck
# data is {id: int, name: str, email: str}
# sendEmail requires {email: str, name: str}
data sendEmail   # valid — id is ignored
```

**Ambiguity rule:** if two functions in scope both match the flowing struct's shape,
it is a compile error. The call site must qualify explicitly.

**Rename at composition:** if a type union produces a field name conflict, the
conflict must be resolved at the composition site:

```tuck
type C = A + B {state -> bState}   # rename B's 'state' field
```

Renaming is validated left-to-right. Renaming to an already-present name is a
compile error.

---

## Part 3: Functions

### 3.1 Functions Are Catalog Entries

There is no `self` keyword. A function is a standalone entry in the catalog. If it
operates on a specific shape, it takes that shape as its first argument explicitly.

```tuck
fn setVolume({player: AudioPlayer, level: int}) -> AudioPlayer:
  player ..level {level}
```

### 3.2 Signatures

Return types are **required** on all function signatures. This seeds the two-pass
type checker with enough information to resolve mutual recursion without forward
declarations. Everything else (local variable types, intermediate expression types)
is inferred.

```tuck
fn classify({celsius: f32}) -> {state: ThermalState}:
  ...
```

### 3.3 Infix Operators in Function Bodies

Inside function bodies, standard infix arithmetic and comparison operators are
permitted. Outside bodies (top-level postfix chains), postfix only. Operators are
just functions with infix calling convention, as in Nim:

```tuck
fn add({a: int, b: int}) -> {result: int}:
  result = a + b       # infix allowed in body

{a: 5, b: 10}.add     # postfix at call site
```

Precedence (high to low): `* / %` → `+ -` → `>= <= != > < ==` → `and or`

### 3.4 Higher-Order Functions via Struct Fields

Passing a function is just passing a struct with a function reference field:

```tuck
fn applyOperation({a: int, b: int, op: fn}) -> {result: int}:
  result = op.invoke {a, b}
```

### 3.5 `bake` — Compile-Time Specialization

`bake` replaces a function-field placeholder with a concrete function reference at
compile time. It is a Factor-language-inspired quotation — the compiler rewrites
the IR, swapping the placeholder for the concrete function, then inlines. No
runtime cost, no boxing:

```tuck
let x = {a: 5, b: 10, someFunc}
let y = x.bake {someFunc: :add}
# y is now exactly: {a: 5, b: 10} with add inlined at the call site
```

`bake` unifies partial application, dependency injection, and the strategy pattern
into one compile-time operation.

### 3.6 Function Prefix Modifiers

Functions can be qualified with a prefix that declares intent and allows the
compiler to enforce constraints:

```tuck
fn   query({filter: Filter}) -> {results: Seq[Episode]}  # reads, no side effects
set  volume({level: int}) -> void                        # uses .., modifies state
pred isReady() -> bool                                   # must be pure, returns bool
```

- `pred` functions must be pure — the compiler rejects any `..` or `[io]` inside them.
- `set` functions must use `..` — the compiler rejects returning a new value.
- `fn` functions are unconstrained.

### 3.7 Effect Markers

A closed set of operational markers in `[]` after the return type. These allow the
checker to enforce constraints without changing language semantics:

```tuck
fn readSensor({port: u8}) -> !{value: u16} [io]:
  ...

fn queuePush({msg: Msg}) -> !void [no_alloc, irq_safe]:
  ...
```

**Initial marker set:** `io`, `alloc`, `no_alloc`, `may_block`, `irq_safe`, `unsafe`

Effect markers propagate upward — a function that calls an `[io]` function is
itself implicitly `[io]`. The checker verifies this. An `[irq_safe]` function
calling an `[io]` function is a compile error.

---

## Part 4: Types

### 4.1 Primitive Types

`bool`, `u8`, `u16`, `u32`, `u64`, `i8`, `i16`, `i32`, `i64`, `f32`, `f64`,
`str`, `usize`

Integers carry an overflow mode declared on the type:

```tuck
distinct SafeRPM   = u16 [saturating]   # clamps at max, never wraps
distinct PacketSeq = u8  [wrapping]     # intentional wraparound
distinct ErrorCount= u32 [trapping]     # debug: panic, release: defined behavior
```

Default for primitive integers: `trapping` in debug, `wrapping` in release.

### 4.2 Distinct Types / Units

Unit types are `distinct` wrappers — same bits at runtime, different types at
compile time. Arithmetic between different unit types is a compile error:

```tuck
distinct Milliseconds = u32
distinct Microseconds = u32
distinct Hertz        = u32

fn delay({ms: Milliseconds}) -> void: ...

delay {5.ms}    # fine
delay {5.us}    # compile error — wrong unit
delay {5}       # compile error — bare int rejected
```

`5.ms` is syntactic sugar for `Milliseconds {5}`. Unit constructor functions are
auto-generated for every `distinct` type.

### 4.3 Sum Types

Sum types model lifecycles and state. You cannot access a field that doesn't exist
on the current variant — the type system enforces valid states without boilerplate:

```tuck
type PodcastPlayerLifecycle:
  | Unloaded({config: Config})
  | Loading({config: Config, progress: int})
  | Ready({config: Config, feed: Feed})
  | Error({config: Config, reason: str})
```

**Exhaustive matching is required.** The compiler rejects any `match` that does not
cover every variant or provide a `_` wildcard.

### 4.4 Sealed Sum Types — Protocol State Machines

The `[sealed]` attribute restricts direct construction to the first (initial)
variant only. All other variants must be reached via declared transitions:

```tuck
type MqttSession [sealed]:
  | Disconnected
  | Connecting({host: str, port: u16})
  | Connected({socket: Socket, keepalive: u16})

  transitions:
    Disconnected -> Connecting
    Connecting   -> Connected
    Connecting   -> Disconnected   # timeout or failure
    Connected    -> Disconnected   # close
```

```tuck
let s = MqttSession.Disconnected        # fine — initial variant
let s = MqttSession.Connected {..}      # compile error — sealed
let s = MqttSession.Connected [unsafe] {..}  # allowed with explicit escape
```

The compiler verifies that every function returning a sealed sum type only produces
variants reachable from its input variant via the declared transition graph.

### 4.5 Type Composition

Types are composed via set union. There is no inheritance:

```tuck
type PodcastPlayer = PodcastPlayerLifecycle + PlaybackControls + CacheManager
```

Field name conflicts are compile errors. Resolve at the composition site with
rename syntax (see 2.5).

### 4.6 Type Attributes

All compiler directives on types use `[]` brackets after the type name, consistent
with effect markers on functions:

```tuck
type EthernetFrame [packed, align: 2]:
  dst:       Array[6, u8]
  src:       Array[6, u8]
  ethertype: u16 [big_endian]    # field-level attribute

type Temperature [invariant: celsius >= -273.15]:
  celsius: f32
```

**Available type attributes:** `packed`, `align: N`, `sealed`, `invariant: expr`,
`saturating`, `wrapping`, `trapping`

**Available field attributes:** `big_endian`, `little_endian`, `volatile`

### 4.7 Invariants

Invariants are runtime asserts — inserted by the compiler at every point where a
value of that type is produced: construction, return value, after mutation, after
deserialization. Stripped in release builds. Zero compiler complexity:

```tuck
type Percentage [invariant: value >= 0 and value <= 100]:
  value: u8
```

The invariant fires automatically everywhere. The developer writes it once.

### 4.8 Error and Absence

- `!T` — the operation might fail
- `?T` — the value might be absent
- `!?T` — both

```tuck
let data = readFile {path}? or return Error.notFound  # propagate failure
let user = findUser {id} or default User.empty        # handle absence
```

`?` propagates the error upward (caller must handle `!T`). `or` provides a
default or early return for absence.

---

## Part 5: Interfaces, Mixins, and the Catalog Model

### 5.1 The Three Buckets

Every Tuck codebase is organized into exactly three kinds of files:

**Domain Files** — the pure, boring truths of the system. Types, sum types, and
pure data transformations. No state mutation, no IO, no concept of the outside
world:

```tuck
# thermal.tuck
type ThermalState: Critical | Hot | Normal

fn classifyTemp({celsius: f32}) -> {state: ThermalState}:
  ...
```

**Mixin Files** — reusable behaviors that operate on domain data. Standalone
functions tagged with `mixin`, waiting to be snapped onto an object. No state of
their own:

```tuck
# retry.mixins.tuck
mixin withRetry:
  fn attempt({maxTries: int}) -> !{result: Self}: ...
```

**Manager Objects** — the assembly layer. Composes domain data with mixins.
Holds `var` state, wires data-flow pipelines. No complex logic permitted (enforced
by the complexity limit):

```tuck
# PodcastPlayer.tuck
object PodcastPlayer:
  + PodcastState
  + AudioOutput
  + withRetry
  + PersistentCache

  fn play({episode: Episode}) -> void:
    self ..loadEpisode ..startAudio
```

### 5.2 Interfaces

Define strict contracts. Objects explicitly declare `satisfies InterfaceName`.
Static checking, no hidden dispatch overhead:

```tuck
interface Storable:
  require:
    fn save({dest: Path}) -> !void
    fn load({src: Path}) -> !Self
```

### 5.3 Interface Dispatch

`ref InterfaceName` is a fat pointer: data pointer + a small function table
containing only the required function fields. At runtime, `item.save` is a struct
field read followed by a call. The function table is minimal — only the fields the
interface declares. The `.field` auto-wrap (Part 2.4) is a compile-time rewrite,
zero runtime cost:

```tuck
var items: Seq[ref Storable] = [doc, user, config]
items.each {item}: item.save {dest: backupPath}
```

### 5.4 The `pending` Block — Walking Skeleton

Allows an app to compile with typed holes so top-down design can proceed before
bottom-up implementation is finished:

```tuck
object PodcastApp:
  fn play({episode: Episode}): ...

  pending:
    fn fetchFeed({url: str}) -> !{feed: Feed}
    fn syncLocal({feed: Feed}) -> !void
```

Compiler flags control runtime behavior of `pending` functions: trap (default in
debug), return zero value (release stub), or log and continue.

---

## Part 6: Correctness Features

### 6.1 Decision Tables

Multi-condition dispatch that the compiler verifies for completeness and
non-ambiguity, then compiles to a bitmask lookup:

```tuck
decision classifyPacket({priority: u2, size: u12, encrypted: bool}) -> Action:
  | high  _     true  -> QueueSecure
  | high  _     false -> QueueFast
  | low   small _     -> QueueDefer
  | _     _     _     -> Drop
```

The compiler:
- Packs conditions into a `uint64` bitmask per row
- Verifies no gaps (unhandled input combinations)
- Verifies no overlaps (ambiguous rows)
- Emits a Nim `case` over a packed integer — zero branches at runtime

Large tables can be split into composed functions. One decision table calls another,
the compiler inlines and builds one combined bitmask table underneath:

```tuck
decision classifySize({bytes: u32}) -> SizeClass: ...

decision routePacket({priority: u2, encrypted: bool, bytes: u32}) -> Action:
  | high  true  Small  -> FastSecure
  | _     _     _      -> routePacket.fallback
```

### 6.2 Static Stack Depth Analysis

For non-recursive Tier 1 code, worst-case stack depth is computable statically.
Declare a budget on any function and the compiler verifies it:

```tuck
fn processISR({event: SensorEvent}) -> void [irq_safe, stack: 128]:
  ...
  # compiler verifies: this fn + all callees use ≤ 128 bytes of stack
```

Algorithm: DFS over the call graph in the IR, summing frame sizes. Recursive calls
are flagged — they are banned in Tier 1 anyway (unbounded stack). The result is a
certification-grade guarantee with zero runtime cost.

### 6.3 Complexity Limit

The compiler enforces a cyclomatic complexity limit of ≤ 5 and approximately
10-15 executable lines per function. This is not a linting suggestion — it is a
compile error. Functions that exceed the limit must be decomposed.

This ensures every function reads like pseudocode, fits in your head, and is
auditable for certification. It forces high-level architecture to remain pure
wiring diagrams.

---

## Part 7: Memory

### 7.1 Tier Model

Tuck is one language everywhere, with strict boundaries:

- **Tier 1 (Application):** Stack-only. Named structs, actors, errors as types,
  no raw pointers, no `ref`, no heap. All structs are value types, copied across
  actor boundaries. The allocator problem doesn't exist.
- **Tier 2 (Library):** Same language + `ref`, `owned ref`, custom allocators,
  SIMD, `when` conditionals, bump and arena allocators.
- **Tier 3 (Systems):** Explicitly Nim. C FFI, MMIO, raw pointers, atomics. A
  concrete substrate, not a vague escape hatch.

### 7.2 Static Memory Pool

Fixed-size object pool. Known at compile time, zero fragmentation, O(1) acquire:

```tuck
pool UartBuffer [size: 64, count: 8]:   # 512 bytes total, statically allocated

let buf = UartBuffer.acquire or return Error.noBuffer
# ... use buf ...
buf.release
```

Internally: a bitmask + a static array. `acquire` is a bitmask scan. `release` is
a bit clear. Declared size is verified against available memory at compile time.

### 7.3 Arena Allocator

Bump-pointer allocator with a clear "frame" lifetime. Reset the whole arena in one
instruction:

```tuck
arena ScratchSpace [size: 2048]:
  let buf   = ScratchSpace.alloc Array[128, u8]
  let frame = ScratchSpace.alloc EthernetFrame
  # process...
  ScratchSpace.reset   # entire arena freed in one pointer assignment
```

Anything allocated from an arena cannot outlive the arena. The compiler enforces
this via scope analysis. No per-object free, no fragmentation, worst-case
allocation time is a pointer increment.

---

## Part 8: Hardware

### 8.1 Register Declarations

Type-safe MMIO. The compiler knows which bits are readable, writable, or
read-with-side-effect:

```tuck
register RCC_CR at 0x40021000:
  HSION:   bit 0     [read, write]
  HSIRDY:  bit 1     [read]           # read-only — writing is a compile error
  HSITRIM: bits 3..7 [read, write]
```

`volatile` is implicit on all register fields. Writing to a read-only field is a
compile error. Reading a write-only field is a compile error.

Register declarations can be generated from vendor-supplied CMSIS-SVD files. One
SVD importer gives type-safe register access for the entire ARM Cortex-M ecosystem.

### 8.2 Compile-Time Size Assertions

```tuck
static_assert sizeof(MqttHeader)      == 2
static_assert alignof(DmaBuffer)      == 4
static_assert offsetof(EtherFrame, ethertype) == 12
```

`offsetof` is included because field-offset bugs in protocol implementations are
common and invisible without it.

### 8.3 `when` Conditionals

Compile-time platform selection. No preprocessor, no `#ifdef` soup:

```tuck
when TARGET == "stm32f4":
  fn initClock() -> void: ...
when TARGET == "rp2040":
  fn initClock() -> void: ...
```

---

## Part 9: Concurrency

### 9.1 Actors

Long-lived isolated state machines. Compile to stackless coroutines — explicit
state machines with static ring buffers. Suitable for 32KB Cortex-M0 environments:

```tuck
actor UartDriver [queue: 8]:
  txBuf: Array[256, u8]

  on send({data: Seq[u8]}) -> void:
    txBuf.copyFrom {data}
    uart.flush {txBuf} [io]     # [io] → implicit yield, others can run

  on select:
    | timer.1s   -> {}:  self.heartbeat
    | shutdown   -> {}:  return    # only way to exit
```

Only value types (copied) cross actor boundaries. No reference sharing across
boundaries. Queue size is declared and statically verified against available memory.

### 9.2 Tasks

Async operations with a defined completion. `[io]`-annotated function calls are
implicit yield points — no `await` keyword, no explicit `yield`. The effect system
IS the yield annotation:

```tuck
task fetchFeed({url: str}) -> !{feed: Feed}:
  let resp = http.get {url}    # [io] → compiler inserts yield here
  resp.body parse              # pure → runs immediately, no yield
```

The compiler transforms the task body into a state machine — one variant per `[io]`
call site, locals that survive across yields become fields of the state enum.

### 9.3 `on select` — Waiting on Multiple Events

Identical syntax in both actors and tasks. A one-shot branch in tasks, a looping
branch in actors:

```tuck
task handleConn({conn: Connection}) -> !void:
  on select:
    | conn.recv   -> {msg}:  msg.process
    | timeout.5s  -> {}:     conn.keepalive
    | shutdown    -> {}:     return
```

### 9.4 The Scheduler

The entire Tuck scheduler is cooperative. Tasks and actors are items in a ready
queue. Each gets one `resume` call per tick, runs until its next `[io]` yield
point, then re-enqueues or parks waiting for a waker. No preemption, no kernel
context switches, no per-task stack allocation.

---

## Part 10: The Event Registry

One global per application. The entire event surface of the system is declared in
one place. No dynamic subscriptions, no cascading, no invisible control flow:

```tuck
registry AppEvents:
  | SensorFailure({port: u8, reason: str})
  | LowMemory({remaining: u32})
  | WatchdogWarning
  | UartOverflow({dropped: u16})
```

**Three operations:**

```tuck
# Raise — signal an event from anywhere
AppEvents.raise SensorFailure {port: 1, reason: "timeout"}

# Handle — declare the one handler for an event, in a manager or actor
on AppEvents.SensorFailure({port, reason}):
  log.warn "sensor {port} failed"
  monitors[port].restart

# Query — poll current state
if AppEvents.latest is LowMemory:
  caches.flush
```

**Compiler guarantees:**
- Every event variant must have at least one handler — an unhandled event type is
  a compile error
- Multiple handlers for the same event are permitted and called in declaration
  order, which is deterministic and visible in the source
- A handler may not raise the same event it handles — trivial infinite loop,
  detected as a cycle at compile time
- `raise` only accepts variants declared in the registry — typos are compile errors
- The entire event surface is visible by reading two things: the `registry`
  declaration and the `on AppEvents.X` handlers

At runtime the registry is a small static array of slots, one per variant, holding
the last payload. `raise` writes the slot and calls all registered handlers in
declaration order, synchronously. No queues, no dynamic allocation, no cascading
to other event types. Each handler returns, the raiser continues.

---

## Part 11: Compiler Architecture

### 11.1 Pipeline

```
Source File
  → Tokenizer (hand-rolled, ~300 lines)
  → Parser (npeg — grammar compiles to zero-overhead Nim procedures)
  → Flat IR (seq[IRNode], index-based, no pointers)
  → Pass 1: Signature Collection (linear scan, builds Tables)
  → Pass 2: Body Checking (bidirectional typing, shape resolution)
  → Cache Write (Merkle hash → msgpack AnalysisEnvelope → .tuck-cache)
  → Emitter (dumb case statement, concatenates Nim source strings)
  → Nim Compiler → Binary
```

### 11.2 The IR

Flat `seq[IRNode]` with index-based references. No pointer chasing, cache-friendly,
trivially serializable with msgpack. Nim's tagged unions (`object of enum`) enforce
exhaustive handling — adding a new IR node kind forces every unhandled `case`
statement to become a compile error:

```nim
type IRKind = enum
  irConst, irName, irFnRef, irStruct, irField,
  irFnDef, irCall, irBake,
  irLet, irVar, irAssign, irBlock, irReturn,
  irIf, irMatch, irFor, irMutate,
  irTypeDecl, irVariant, irTransition,
  irDecision, irDecisionRow,
  irActor, irOnHandler, irTask, irSelect,
  irEventRegistry, irRaise, irOnEvent,
  irPool, irArena, irRegister, irPending

type NodeIdx  = distinct int32
type OptNode  = Option[NodeIdx]
type FieldDef = tuple[name, typ: string]
type IfBranch = tuple[cond: OptNode, body: NodeIdx]
type MatchArm = tuple[variant: string, body: NodeIdx]
```

### 11.3 Pass 1 — Signature Collection

One linear scan of the IR. Only examines top-level declarations. Builds:

- `sigs:   Table[string, FnSig]` — all function names → signatures
- `shapes: Table[string, FieldSet]` — all type names → field sets
- `graphs: Table[string, TransGraph]` — all sealed types → transition adjacency lists

Return types are explicit on all signatures. This seeds pass 1 with enough
information to resolve mutual recursion without forward declarations. Two mutually
recursive functions are both in the signature table before either body is checked.

Each top-level declaration is Merkle-hashed. Cache hits skip pass 2 entirely.

### 11.4 Pass 2 — Body Checking

Works only on cache-miss declarations. For each function body:

- Resolve every call: `synthesize(arg shape) ⊆ required(fn param shape)`
- Check `match` exhaustiveness
- Check `..` only on `var` bindings
- Check effect marker propagation
- Verify complexity ≤ 5
- Verify stack budget if declared

For each sealed type: verify all match arms in all functions only produce
transition-graph-reachable variants.

For each decision table: build bitmask, check coverage and overlaps.

For each actor/task: verify queue sizes fit in declared memory tier.

**Error handling:** collect all errors in the current declaration, continue to the
next. One bad function does not prevent checking the rest of the file.

### 11.5 The Cache

Content-addressable, append-only binary file (`.tuck-cache`), loaded entirely into
RAM as `Table[Hash, seq[byte]]`.

- **Key:** Merkle hash = `Hash(AST bytes + hashes of all dependencies)`. Changing
  a dependency mathematically invalidates the parent.
- **Value:** msgpack `AnalysisEnvelope` with three slots:
  1. `Summary` — input shape, output shape, effect markers, complexity score
  2. `BaseIR` — flattened, desugared IR nodes
  3. `Specialized` — bitmask tables (decisions), transition graphs (actors/sealed
     types), stack depth results

### 11.6 The Emitter

A dumb `case` statement over `IRKind` that concatenates Nim source strings. Never
builds a Nim AST. This is intentional — the emitter is not where bugs live. All
correctness work happens in pass 2.

Special cases:
- `irDecision` → Nim `case` over a packed `uint64`
- `irActor` → Nim closure with `while true` + case over message types
- `irTask` → Nim state machine proc with one variant per `[io]` yield point
- `irRegister` → `volatile` field access with inline endian swap if `[big_endian]`

### 11.7 Bidirectional Typing

Two functions, mutually recursive:

- `check(expr, expectedType)` — push a known type down into an expression
- `synthesize(expr)` — pull an unknown type up from an expression

Return types on signatures make this tractable. Genuine cycles (where no annotation
exists to seed inference) are compile errors with a clear message asking for an
explicit return type annotation. In practice this is rare — Tuck's explicit
signature style means the annotation is almost always already there.

### 11.8 Performance Targets

- < 100ms single file
- < 500ms full project rebuild (cache cold)
- < 10ms incremental (cache warm, one function changed)
- LSP integration from day one — the checker produces source-span-tagged errors,
  which is all an LSP needs

---

## Part 12: Grammar Sketch (npeg)

The parser uses npeg, which compiles the grammar to Nim procedures at compile time.
Action blocks fire during parsing and write directly into the flat IR — no
intermediate CST is materialized.

Key rules:

```nim
# Indentation — INDENT/DEDENT tokens emitted by the hand-rolled tokenizer
# Tabs banned at the tokenizer level — hard error

# Identifiers
loIdent <- >(Alpha | '_') * *(Alnum | '_')   # foo_bar
upIdent <- >Upper * *(Alnum | '_')            # FooBar

# Type expressions
baseType  <- ("!?" * typeExpr) | ("!" * typeExpr) | ("?" * typeExpr)
           | upIdent | structType
typeExpr  <- baseType * *("+" * baseType)    # T + U + V
typeAttrs <- "[" * attrList * "]"            # [packed, align: 4]

# Struct literals
structLit <- "{" * *((loIdent * ":" * expr | loIdent) * ?",") * "}"

# Expressions — infix only inside function bodies
primary   <- literal | structLit | "(" * expr * ")" | loIdent | upIdent
postfixOp <- (".." * loIdent * ?structLit)   # mutation
           | ("."  * loIdent)                    # field access
           | ("[" * expr * "]")              # index
           | "?"                                # error propagate
           | ("::" * loIdent)                   # function ref
postfix   <- primary * *postfixOp
app       <- postfix +                        # implicit whitespace invocation
expr      <- app * *(infixOp * app)           # infix in bodies

# Function signatures — return type always required
fnSig   <- "fn" * >loIdent * "(" * *param * ")" * "->" * >typeExpr
         * ?("[" * >effectList * "]")

# Sum types with optional transitions
typeDecl <- "type" * >upIdent * ?typeAttrs * ":" * nl
          * +sumVariant * ?transitions

# Sealed transitions
transitions  <- "transitions" * ":" * nl * +transitionRow
transitionRow <- >upIdent * "->" * >upIdent * nl

# Decision tables
decisionDecl <- "decision" * >loIdent * "(" * structType * ")" * "->" * typeExpr
              * ":" * nl * +decisionRow
decisionRow  <- "|" * +(expr) * "->" * expr * nl

# Actors and tasks — same on/select syntax
actor  <- "actor" * >upIdent * ?typeAttrs * ":" * nl * +(varDecl | onHandler)
task   <- "task"  * >loIdent * "(" * *param * ")" * "->" * typeExpr * ":" * block
onHandler <- "on" * (loIdent * ?structType * ?("->" * typeExpr) * ":" * block
           | "select" * ":" * nl * +selectArm)
selectArm <- "|" * expr * "->" * structLit * ":" * stmt * nl

# Event registry
registry <- "registry" * >upIdent * ":" * nl * +sumVariant

# Top level
topDecl <- fnDecl | typeDecl | objDecl | mixinDecl | ifaceDecl
         | actorDecl | taskDecl | registryDecl | decisionDecl
         | letStmt | varStmt
```

---

## Appendix A: Open Questions

Items deferred, not forgotten:

1. **Generics / parametric types** — `Seq[T]`, `Option[T]` used throughout but
   not yet specified. Likely a simple substitution model, no HKTs.
2. **Module system** — how files import each other, visibility rules.
3. **SVD importer** — tooling to generate register declarations from vendor XML.
4. **Deferred logging** (`defmt`-style) — format-string-ID protocol. Specified as
   a standard library mixin, not a language feature.
5. **Protocol state machines on message sequences** — valid ordering of messages,
   not just valid message shapes. Post-v1.
6. **LSP protocol** — error format, incremental re-check triggers.

---

## Appendix B: What Tuck Does Not Have

These are deliberate omissions, not oversights:

- Null / nil
- Exceptions
- Inheritance
- Vtables (dispatch is fat pointer field reads)
- `self` keyword
- Forward declarations
- Preprocessor / macros
- Implicit conversions
- Global mutable state (except the one declared `registry`)
- Heap allocation in Tier 1
- Recursion in Tier 1
- Preemptive scheduling

---

*End of specification.*
