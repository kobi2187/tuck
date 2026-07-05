**TUCK**

Language Specification & Product Requirements

_Version 0.1 — Working Draft_

_A systems-capable language for embedded and constrained environments. Maintainability, obviousness, and fearless refactoring._

# **Part 1 — Philosophy**

Tuck is a systems-capable language designed primarily for embedded and constrained environments, suitable for general application development. It targets the gap where C is fifty years old, C++ brings hidden costs, and Rust’s ownership model fights against embedded patterns.

The goal is not academic novelty. The goal is maintainability, obviousness, and fearless refactoring. Programs always grow. Debugging is hard and slow. The language must make everything explicit, locatable, and auditable.

Tuck achieves this through a single radical constraint:

_Every piece of data flows through the system as a named struct._

By restricting the shape of code, Tuck frees the programmer to focus entirely on the shape of data. The result is a language that feels like a catalog of tiny, obvious, unbreakable blocks snapping together.

## **1.1 — One Answer Per Concern**

For every major concern, Tuck has exactly one answer. There are no two ways to do any of these things:

**Concern**

**Answer**

State

Sum types with sealed transitions

Errors

!T propagation with or

Absence

?T with or

Side effects

Effect markers \[io, no\_alloc, ...\]

Shared mutable state

Actors with typed message queues

Short async operations

Tasks — \[io\] functions yield implicitly

App-wide signals

One registry, one or more handlers per event

Hardware access

Register declarations, units, packed types

Correctness

Decision tables, transition graphs, invariant asserts

Composition

Domain files, mixins, manager objects

# **Part 2 — The Universal Shape**

## **2.1 — Named Structs Are the Only Container**

In Lisp, everything is a list. In Forth, everything is a stack. In Tuck, everything is a named struct. A single integer is conceptually `{value: 5}`. The compiler allows syntactic sugar but semantically it is always a struct. The backend optimizes the wrapping away completely.

let request = {url: "example.com", timeout: 5.ms}
let response = request fetch parse episodes

var feed = {url: "..."} fetch

if feed.hasNew:
  feed.episodes process
else:
  feed.metadata log

## **2.2 — No Destructuring**

You do not unpack a struct into local variables. If you need a field, access it via .fieldName on the flowing struct or the bound variable. The struct flows as a whole.

## **2.3 — Postfix Invocation vs. Mutation**

Two distinct surface forms keep pure calls and stateful mutation separate:

*   whitespace — implicit function invocation. The previous struct is passed as the single payload to the next function.
*   .. (DotDot) — Mutation / builder. Modifies a bound var in place and returns it for further chaining.

# Functional pipeline

let result = {config} connect query

# Builder pattern on a var

var server = ServerConfig {}
server ..port {8080} ..timeout {30.seconds} ..start

Mutating a struct requires using `..` on a `var`. The compiler rejects `..` on `let` bindings. This friction is intentional.

## **2.4 — Field Access Auto-Wrap**

Accessing a single field wraps it automatically into a single-field struct so function uniformity is preserved. This is a compile-time rewrite with zero runtime cost:

player.volume normalize

# volume: int → {value: int} → passed to normalize

## **2.5 — Subset Matching**

If a flowing struct contains more fields than a function requires, the extra fields are silently ignored:

\# data is {id: int, name: str, email: str}

\# sendEmail requires {email: str, name: str}

data sendEmail # valid — id is ignored

Ambiguity rule: if two functions both match the flowing struct’s shape, it is a compile error. The call site must qualify explicitly.

Rename at composition: field name conflicts in type unions must be resolved at the composition site:

type C = A + B {state -> bState} # rename B's 'state' field

Renaming is validated left-to-right. Renaming to an already-present name is a compile error.

# **Part 3 — Functions**

## **3.1 — Functions Are Catalog Entries**

There is no self keyword. A function is a standalone entry in the catalog. If it operates on a specific shape, it takes that shape as its first argument explicitly:

fn setVolume({player: AudioPlayer, level: int}) -> AudioPlayer:

player ..level {level}

## **3.2 — Signatures**

Return types are required on all function signatures. This seeds the two-pass type checker with enough information to resolve mutual recursion without forward declarations. Local variable types and intermediate expressions are inferred.

## **3.3 — Infix Operators in Function Bodies**

Inside function bodies, standard infix arithmetic and comparison operators are permitted. Outside bodies, postfix only. Operators are functions with infix calling convention, as in Nim.

Precedence (high to low): \* / % → + - → >= <= != > < == → and or

## **3.4 — Higher-Order Functions via Struct Fields**

Passing a function is just passing a struct with a function reference field:

fn applyOperation({a: int, b: int, op: fn}) -> {result: int}:

result = op.invoke {a, b}

## **3.5 — \`bake\` — Compile-Time Specialization**

bake replaces a function-field placeholder with a concrete function reference at compile time. Inspired by Factor-language quotations. The compiler rewrites the IR, swaps the placeholder, then inlines. No runtime cost, no boxing:

let x = {a: 5, b: 10, someFunc}

let y = x.bake {someFunc: :add}

\# y is now {a: 5, b: 10} with add inlined at every call site

bake unifies partial application, dependency injection, and the strategy pattern into one compile-time operation.

## **3.6 — Function Prefix Modifiers**

fn query({filter: Filter}) -> {results: Seq\[Episode\]}

set volume({level: int}) -> void

pred isReady() -> bool

*   pred functions must be pure — compiler rejects any .. or \[io\] inside them.
*   set functions must use .. — compiler rejects returning a new value.
*   fn functions are unconstrained.

## **3.7 — Effect Markers**

A closed set of operational markers in \[\] after the return type. They allow the checker to enforce constraints without changing language semantics:

fn readSensor({port: u8}) -> !{value: u16} \[io\]: ...

fn queuePush({msg: Msg}) -> !void \[no\_alloc, irq\_safe\]: ...

Initial marker set: io, alloc, no\_alloc, may\_block, irq\_safe, unsafe

Effect markers propagate upward. A function that calls an \[io\] function is itself implicitly \[io\]. An \[irq\_safe\] function calling an \[io\] function is a compile error.

# **Part 4 — Types**

## **4.1 — Primitive Types**

bool, u8, u16, u32, u64, i8, i16, i32, i64, f32, f64, str, usize

Integers carry an overflow mode declared on the type:

distinct SafeRPM = u16 \[saturating\] # clamps at max, never wraps

distinct PacketSeq = u8 \[wrapping\] # intentional wraparound

distinct ErrorCount = u32 \[trapping\] # debug: panic; release: defined

Default for primitive integers: trapping in debug, wrapping in release.

## **4.2 — Distinct Types / Units**

Unit types are distinct wrappers — same bits at runtime, different types at compile time. Arithmetic between different unit types is a compile error:

distinct Milliseconds = u32

distinct Microseconds = u32

fn delay({ms: Milliseconds}) -> void: ...

delay {5.ms} # fine

delay {5.us} # compile error — wrong unit

delay {5} # compile error — bare int rejected

5.ms is syntactic sugar for Milliseconds {5}. Unit constructors are auto-generated for every distinct type.

## **4.3 — Sum Types**

Sum types model lifecycles and state. You cannot access a field that doesn’t exist on the current variant:

type PodcastPlayerLifecycle:

| Unloaded({config: Config})

| Loading({config: Config, progress: int})

| Ready({config: Config, feed: Feed})

| Error({config: Config, reason: str})

Exhaustive matching is required. The compiler rejects any match that does not cover every variant or provide a \_ wildcard.

## **4.4 — Sealed Sum Types — Protocol State Machines**

The \[sealed\] attribute restricts direct construction to the first (initial) variant only. All other variants must be reached via declared transitions:

type MqttSession \[sealed\]:

| Disconnected

| Connecting({host: str, port: u16})

| Connected({socket: Socket, keepalive: u16})

transitions:

Disconnected -> Connecting

Connecting -> Connected

Connecting -> Disconnected # timeout / failure

Connected -> Disconnected # close

let s = MqttSession.Disconnected # fine — initial variant

let s = MqttSession.Connected {..} # compile error — sealed

let s = MqttSession.Connected \[unsafe\] {..} # allowed with explicit escape

The compiler verifies that every function returning a sealed sum type only produces variants reachable from its input via the declared transition graph.

## **4.5 — Type Composition**

Types are composed via set union. There is no inheritance:

type PodcastPlayer = PodcastPlayerLifecycle + PlaybackControls + CacheManager

Field name conflicts are compile errors. Resolve at the composition site with rename syntax.

## **4.6 — Type Attributes**

All compiler directives on types use \[\] brackets after the type name, consistent with effect markers on functions:

type EthernetFrame \[packed, align: 2\]:

dst: Array\[6, u8\]

src: Array\[6, u8\]

ethertype: u16 \[big\_endian\]

type Temperature \[invariant: celsius >= -273.15\]:

celsius: f32

Available type attributes: packed, align: N, sealed, invariant: expr, saturating, wrapping, trapping

Available field attributes: big\_endian, little\_endian, volatile

## **4.7 — Invariants**

Invariants are runtime asserts inserted by the compiler at every point where a value of that type is produced: construction, return value, after mutation, after deserialization. Stripped in release builds:

type Percentage \[invariant: value >= 0 and value <= 100\]:

value: u8

The developer writes the invariant once. The compiler inserts it everywhere automatically.

## **4.8 — Error and Absence**

*   !T — the operation might fail
*   ?T — the value might be absent
*   !?T — both

let data = readFile {path}? or return Error.notFound

let user = findUser {id} or default User.empty

# **Part 5 — Interfaces, Mixins & the Catalog Model**

## **5.1 — The Three Buckets**

Every Tuck codebase is organized into exactly three kinds of files:

### **Domain Files — The Reality**

Pure, boring truths of the system. Types, sum types, and pure data transformations. No state mutation, no IO, no concept of the outside world:

\# thermal.tuck

type ThermalState: Critical | Hot | Normal

fn classifyTemp({celsius: f32}) -> {state: ThermalState}: ...

### **Mixin Files — The Capabilities**

Reusable behaviors that operate on domain data. Standalone functions tagged with mixin. No state of their own:

\# retry.mixins.tuck

mixin withRetry:

fn attempt({maxTries: int}) -> !{result: Self}: ...

### **Manager Objects — The Assembly**

Composes domain data with mixins. Holds var state, wires data-flow pipelines. No complex logic permitted (enforced by the complexity limit):

\# PodcastPlayer.tuck

object PodcastPlayer:

\+ PodcastState

\+ AudioOutput

\+ withRetry

\+ PersistentCache

fn play({episode: Episode}) -> void:

self ..loadEpisode ..startAudio

## **5.2 — Interfaces**

Define strict contracts. Objects explicitly declare satisfies InterfaceName. Static checking, no hidden dispatch overhead:

interface Storable:

require:

fn save({dest: Path}) -> !void

fn load({src: Path}) -> !Self

## **5.3 — Interface Dispatch**

ref InterfaceName is a fat pointer: data pointer + a minimal function table containing only the required function fields. At runtime, item.save is a struct field read followed by a call:

var items: Seq\[ref Storable\] = \[doc, user, config\]

items.each {item}: item.save {dest: backupPath}

## **5.4 — The \`pending\` Block**

Allows an app to compile with typed holes so top-down design can proceed before bottom-up implementation is finished:

object PodcastApp:

fn play({episode: Episode}): ...

pending:

fn fetchFeed({url: str}) -> !{feed: Feed}

fn syncLocal({feed: Feed}) -> !void

Compiler flags control runtime behavior of pending functions: trap (debug default), return zero value (release stub), or log and continue.

# **Part 6 — Correctness Features**

## **6.1 — Decision Tables**

Multi-condition dispatch that the compiler verifies for completeness and non-ambiguity, then compiles to a bitmask lookup with zero branches at runtime:

decision classifyPacket({priority: u2, size: u12, encrypted: bool}) -> Action:

| high \_ true -> QueueSecure

| high \_ false -> QueueFast

| low small \_ -> QueueDefer

| \_ \_ \_ -> Drop

The compiler packs conditions into a uint64 bitmask per row, verifies no gaps (unhandled input combinations), verifies no overlaps (ambiguous rows), and emits a Nim case over a packed integer.

Large tables can be split into composed functions. The compiler inlines and builds one combined bitmask underneath.

## **6.2 — Static Stack Depth Analysis**

For non-recursive Tier 1 code, worst-case stack depth is computable statically. Declare a budget and the compiler verifies it:

fn processISR({event: SensorEvent}) -> void \[irq\_safe, stack: 128\]:

\# compiler verifies: this fn + all callees ≤ 128 bytes of stack

Algorithm: DFS over the call graph in the IR, summing frame sizes. Recursive calls are flagged — banned in Tier 1. The result is a certification-grade guarantee with zero runtime cost.

## **6.3 — Complexity Limit**

The compiler enforces a cyclomatic complexity limit of ≤ 5 and approximately 10–15 executable lines per function. This is a compile error, not a lint warning. Functions that exceed the limit must be decomposed.

_This ensures every function reads like pseudocode, fits in one’s head, and is auditable for certification. High-level architecture remains pure wiring diagrams._

# **Part 7 — Memory**

## **7.1 — Tier Model**

**Tier**

**Name**

**Capabilities**

1

Application

Stack-only. Named structs, actors, errors as types, no raw pointers, no ref, no heap. All structs are value types, copied across actor boundaries.

2

Library

Same as Tier 1 plus ref, owned ref, custom allocators, SIMD, when conditionals, bump and arena allocators.

3

Systems

Explicitly Nim. C FFI, MMIO, raw pointers, atomics. A concrete substrate, not a vague escape hatch.

## **7.2 — Static Memory Pool**

Fixed-size object pool. Known at compile time, zero fragmentation, O(1) acquire:

pool UartBuffer \[size: 64, count: 8\]: # 512 bytes total, static

let buf = UartBuffer.acquire or return Error.noBuffer

\# ... use buf ...

buf.release

Internally: a bitmask + a static array. acquire is a bitmask scan, release is a bit clear. Declared size is verified against available memory at compile time.

## **7.3 — Arena Allocator**

Bump-pointer allocator with a clear frame lifetime. Reset the whole arena in one instruction:

arena ScratchSpace \[size: 2048\]:

let buf = ScratchSpace.alloc Array\[128, u8\]

let frame = ScratchSpace.alloc EthernetFrame

ScratchSpace.reset # entire arena freed in one pointer assignment

Anything allocated from an arena cannot outlive the arena — enforced by scope analysis. No per-object free, no fragmentation.

# **Part 8 — Hardware**

## **8.1 — Register Declarations**

Type-safe MMIO. The compiler knows which bits are readable, writable, or read-with-side-effect. volatile is implicit on all register fields:

register RCC\_CR at 0x40021000:

HSION: bit 0 \[read, write\]

HSIRDY: bit 1 \[read\] # read-only — writing is a compile error

HSITRIM: bits 3..7 \[read, write\]

Register declarations can be generated from vendor-supplied CMSIS-SVD files. One SVD importer gives type-safe register access for the entire ARM Cortex-M ecosystem.

## **8.2 — Compile-Time Size Assertions**

static\_assert sizeof(MqttHeader) == 2

static\_assert alignof(DmaBuffer) == 4

static\_assert offsetof(EtherFrame, ethertype) == 12

offsetof is included because field-offset bugs in protocol implementations are common and invisible without it.

## **8.3 — \`when\` Conditionals**

Compile-time platform selection. No preprocessor, no #ifdef soup:

when TARGET == "stm32f4":

fn initClock() -> void: ...

when TARGET == "rp2040":

fn initClock() -> void: ...

# **Part 9 — Concurrency**

## **9.1 — Actors**

Long-lived isolated state machines. Compile to stackless coroutines with static ring buffers. Suitable for 32KB Cortex-M0 environments. Only value types cross actor boundaries — no reference sharing:

actor UartDriver \[queue: 8\]:

txBuf: Array\[256, u8\]

on send({data: Seq\[u8\]}) -> void:

txBuf.copyFrom {data}

uart.flush {txBuf} \[io\] # \[io\] → implicit yield

on select:

| timer.1s -> {}: self.heartbeat

| shutdown -> {}: return

## **9.2 — Tasks**

Async operations with a defined completion. \[io\]-annotated function calls are implicit yield points. No await keyword. The effect system IS the yield annotation:

task fetchFeed({url: str}) -> !{feed: Feed}:

  let resp = http.get {url} # [io] → compiler inserts yield here

  resp.body parse # pure → no yield

The compiler transforms the task body into a state machine — one variant per \[io\] call site, locals that survive across yields become fields of the state enum.

## **9.3 — \`on select\` — Waiting on Multiple Events**

Identical syntax in both actors and tasks. A one-shot branch in tasks, a looping branch in actors:

task handleConn({conn: Connection}) -> !void:

on select:

| conn.recv -> {msg}: msg.process

| timeout.5s -> {}: conn.keepalive

| shutdown -> {}: return

## **9.4 — The Scheduler**

Purely cooperative. Tasks and actors are items in a ready queue. Each gets one resume call per tick, runs until its next \[io\] yield point, then re-enqueues or parks waiting for a waker. No preemption, no kernel context switches, no per-task stack allocation.

# **Part 10 — The Event Registry**

One global per application. The entire event surface of the system is declared in one place. No dynamic subscriptions, no cascading, no invisible control flow:

registry AppEvents:

| SensorFailure({port: u8, reason: str})

| LowMemory({remaining: u32})

| WatchdogWarning

| UartOverflow({dropped: u16})

## **10.1 — Three Operations**

\# Raise — signal an event from anywhere

AppEvents.raise SensorFailure {port: 1, reason: "timeout"}

\# Handle — declare a handler, in a manager or actor

on AppEvents.SensorFailure({port, reason}):

log.warn "sensor {port} failed"

monitors\[port\].restart

\# Query — poll current state

if AppEvents.latest is LowMemory:

caches.flush

## **10.2 — Compiler Guarantees**

*   Every event variant must have at least one handler — unhandled event is a compile error.
*   Multiple handlers for the same event are permitted and called in declaration order.
*   A handler may not raise the same event it handles — trivial cycle, compile error.
*   raise only accepts variants declared in the registry — typos are compile errors.

_At runtime the registry is a small static array of slots, one per variant. \`raise\` writes the slot and calls all registered handlers synchronously in declaration order. No queues, no dynamic allocation, no cascading._

# **Part 11 — Compiler Architecture**

## **11.1 — Pipeline**

Source File

→ Tokenizer (hand-rolled, ~300 lines; emits INDENT/DEDENT; bans tabs)

→ Parser (npeg; grammar compiles to zero-overhead Nim procedures)

→ Flat IR (seq\[IRNode\], index-based, no pointers)

→ Pass 1 (signature collection; linear scan; builds Tables)

→ Pass 2 (body checking; bidirectional typing; shape resolution)

→ Cache Write (Merkle hash → msgpack AnalysisEnvelope → .tuck-cache)

→ Emitter (dumb case statement; concatenates Nim source strings)

→ Nim Compiler → Binary

## **11.2 — The IR**

Flat seq\[IRNode\] with index-based references. No pointer chasing, cache-friendly, trivially serializable with msgpack. Nim’s tagged unions enforce exhaustive handling — adding a new IR node kind causes every unhandled case to become a compile error.

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

type NodeIdx = distinct int32

type OptNode = Option\[NodeIdx\]

type FieldDef = tuple\[name, typ: string\]

## **11.3 — Pass 1 — Signature Collection**

One linear scan of the IR. Only examines top-level declarations. Builds:

*   sigs: Table\[string, FnSig\] — all function names → signatures
*   shapes: Table\[string, FieldSet\] — all type names → field sets
*   graphs: Table\[string, TransGraph\] — all sealed types → transition adjacency lists

Return types are explicit on all signatures. This seeds pass 1 with enough information to resolve mutual recursion without forward declarations. Each top-level declaration is Merkle-hashed; cache hits skip pass 2 entirely.

## **11.4 — Pass 2 — Body Checking**

Works only on cache-miss declarations. For each function body:

*   Resolve every call: synthesize(arg shape) ⊆ required(fn param shape)
*   Check match exhaustiveness
*   Check .. only on var bindings
*   Check effect marker propagation
*   Verify complexity ≤ 5
*   Verify stack budget if declared

Error handling: collect all errors in the current declaration, continue to the next. One bad function does not prevent checking the rest of the file.

## **11.5 — The Cache**

Content-addressable, append-only binary file (.tuck-cache), loaded entirely into RAM as Table\[Hash, seq\[byte\]\].

*   Key: Merkle hash = Hash(AST bytes + hashes of all dependencies). Changing a dependency mathematically invalidates the parent.
*   Value: msgpack AnalysisEnvelope with three slots: Summary (input/output shapes, effect markers, complexity), BaseIR (flattened desugared nodes), Specialized (bitmask tables, transition graphs, stack depth results).

## **11.6 — The Emitter**

A dumb case statement over IRKind that concatenates Nim source strings. Never builds a Nim AST. All correctness work happens in pass 2.

*   irDecision → Nim case over a packed uint64
*   irActor → Nim closure with while true + case over message types
*   irTask → Nim state machine proc with one variant per \[io\] yield point
*   irRegister → volatile field access with inline endian swap if \[big\_endian\]

## **11.7 — Performance Targets**

**Scenario**

**Target**

Single file, cold

< 100ms

Full project, cold cache

< 500ms

Incremental, one function changed

< 10ms

LSP re-check on keypress

< 50ms

# **Appendix A — Open Questions**

Items deferred, not forgotten:

*   Generics / parametric types — Seq\[T\], Option\[T\] used throughout but not yet specified. Likely a simple substitution model, no higher-kinded types.
*   Module system — how files import each other, visibility rules.
*   SVD importer — tooling to generate register declarations from vendor CMSIS-SVD XML.
*   Deferred logging (defmt-style) — format-string-ID protocol. Specified as a standard library mixin, not a language feature.
*   Protocol state machines on message sequences — valid ordering of messages, not just valid message shapes. Post-v1.
*   LSP protocol — error format, incremental re-check trigger design.

# **Appendix B — Deliberate Omissions**

These are intentional design decisions, not oversights:

**Omitted**

**Reason**

Null / nil

Replaced by ?T with explicit handling

Exceptions

Replaced by !T propagation and event registry

Inheritance

Replaced by type composition via set union

Vtables

Dispatch is fat pointer field reads

self keyword

Functions are standalone catalog entries

Forward declarations

Two-pass signature collection eliminates the need

Preprocessor / macros

Replaced by when, bake, and distinct

Implicit conversions

All conversions are explicit and named

Global mutable state

One declared registry is the only global

Heap allocation in Tier 1

Stack-only is a correctness feature, not a restriction

Recursion in Tier 1

Unbounded stack depth is unacceptable on constrained hardware

Preemptive scheduling

Cooperative scheduling is sufficient and auditable

_— End of Document —_