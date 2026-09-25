# Tuck

**Tuck is a language for building programs the way you actually think about them: big picture first, details later, with the compiler covering your back the whole way.**

Tuck aims for rapid development and short iteration cycles with as little head scratching as possible. It tries to remove whole classes of bugs along the way, so they can't happen at all, rather than just making them less likely. It's a systems language that transpiles to **Nim**, **Odin** and **D**. If you do embedded work and have ever wanted something between the freedom of C and the ceremony of Rust, I'd love for you to try it.

```tuck
let response = request fetch parse selectEpisodes
```

That's the core idea in one line. Data flows left to right through transformations. Every function has the same shape, **one named struct in and one named struct out**, so composing them is effortless.

## Design top-down, the way you already do

When you design an app, you don't start with the parser helper on line 400. You brainstorm. You figure out the big parts, like "there's a player, it has a cache, it talks to the network, something handles downloads in the background." Then you work your way down.

Most languages make you build from the bottom up before anything runs. Tuck lets you work in the order you think.

### Name the big parts with interfaces

Interfaces in Tuck are **design tools**. You can declare one before anything implements it and design the rest of the program against it:

```tuck
interface Storage:
  fn get({self: Self, key: str}) -> ?str
  fn put({self: Self, key: str, value: str}) -> void
```

Whether it ends up as a file, memory, or a database is a later decision. The architecture exists before the implementations do.

### Build from managers, which are your mental model

The functionality you *anticipate* ("this thing plays audio," "this thing caches") becomes a **manager**: a small type that carries both its data and its behaviour. Then you snap managers together:

```tuck
type PodcastPlayer = PlayerLifecycle + PlaybackControls + CacheManager
```

That line reads like how you'd describe the player out loud, and that's on purpose. The code keeps the shape of your mental model.

Over time, managers become your personal catalog. They get reused the way libraries do, but they're more modular: you don't *call into* a manager, you *snap it into* whatever needs it. There's no hierarchy to plan up front and no inheritance chain to untangle later.

### Give the living parts to actors

Some parts of a program have a life of their own: a sensor, a network link, a download queue, a UI event loop. In Tuck those are **actors**.

An actor is a singleton with its own private state and a mailbox. It handles one message at a time. You never share its state, pass it around, or wonder who else is touching it. That makes actors easy to reason about. You can picture each one as a little box that receives messages and changes state, and your whole app as a handful of those boxes talking to each other.

Actors are a first-class part of Tuck, not a library bolted on. When a program grows, they're how it stays understandable.

### Then make it run, before it does anything

Now you write down what the program needs, as typed holes:

```tuck
pending:
  fn fetch({url: str}) -> {hasNew: bool, episodes: int, metadata: str}
  fn parse({hasNew: bool, episodes: int, metadata: str}) -> {episodes: int}
  fn selectEpisodes({episodes: int}) -> {episodes: int}
```

This is a **walking skeleton**. It compiles and runs. The holes are type-checked against their signatures, and the compiler generates stubs that log each call and return zero values. You can watch your architecture execute on day one.

Every build prints what's still pending. When you implement something and forget to take it off the list, the compiler reminds you. It's a TODO list that can't rot.

## Iterate fast, without leaving landmines

From here you fill holes one at a time, and the program keeps running the whole way.

While exploring, you can relax error handling (`continue` or `exit` policy) so an unfinished corner doesn't block you. The compiler keeps a `SHORTCUTS` report of every corner you cut. When you're ready to ship, switch to `strict` and clear the list.

The short cycles come from functions staying small, data flowing in straight lines, and every diagnostic having a permanent code with an explanation (`tuck explain TK-TY15`). When something breaks, there just aren't many places for it to hide.

## Declare the rules, don't scatter them

A lot of bugs live in logic spread across `if` statements in five files. Tuck lets you write that logic down once, as a declaration the compiler checks.

**Sealed state machines.** Only the listed transitions are legal:

```tuck
type PlayerLifecycle:
  | Unloaded({config: Config})
  | Loading({config: Config, progress: int})
  | Ready({config: Config, feed: Feed})

  transitions:
    Unloaded -> Loading
    Loading  -> Ready
    Loading  -> Unloaded   # cancel/timeout
    Ready    -> Unloaded   # reset
```

**Decision tables.** Missing combinations and dead rows are reported with their concrete values:

```tuck
decision classifyPacket({priority: Priority, size: SizeClass, encrypted: bool}) -> Action:
  | high    big   true  -> QueueSecure
  | high    big   false -> QueueFast
  | high    small _     -> QueueImmediate
  | low     _     _     -> QueueDefer
```

**Invariants.** A value can't exist in a state you've ruled out:

```tuck
type Temperature:
  celsius: f32
  invariant:
    celsius >= -273.15
```

You write the logic the way you'd explain it on a whiteboard, and the compiler turns it into tight low-level code. The decision table above becomes a single `case` over a packed key.

## Whole bug classes, gone

A lot of Tuck's safety comes from things you simply can't write:

- **No use of uninitialized values.**
- **No silent errors.** `!T` can fail and `?T` can be empty, and ignoring either is a compile error.
- **No hidden effects.** A function that does I/O says `[io]` in its signature, at every level.
- **No illegal state changes.** Sealed transitions make sure only declared moves happen.
- **No forgotten cases.** Decision tables and matches are checked for completeness and reachability.
- **No spooky mutation.** Changes are spelled `..field`, and a function can't modify what you pass it.
- **No unhandled events.** Every event in the registry needs a handler, or the build fails.

## The value semantics experiment

Tuck has **no references**. Everything is a value. Behind the scenes, records are passed by pointer so it stays fast, but the checker guarantees nobody can write through them. You get cheap passing without aliasing surprises.

This is a deliberate experiment: *how far can we push value semantics before we genuinely need references?* So far, further than you might expect. Composed objects, actors, interface collections and even recursive trees (`Add({left: Expr, right: Expr})`) all work without a single user-visible pointer. The next frontier is shared and cyclic structures, where a slab (an owned arena plus indices) looks like the answer.

There's a nice side effect for the compiler, too. No aliasing, declared effects, closed sets of interface types and explicit state graphs are exactly the facts optimizers usually have to work hard to prove. In Tuck you've already stated them. Seeing how much speed that buys is part of the fun.

## For embedded folks

Tuck was designed with embedded work in mind, as an alternative for people who want more safety than C gives them without taking on Rust's learning curve. You can describe the hardware directly:

```tuck
type SafeRPM   = u16 [saturating]   # clamps at 65535, never wraps
type PacketSeq = u8  [wrapping]     # wraparound on purpose

register RCC_CR at 0x40021000:
  HSION:  bit 0  [read, write]
  HSIRDY: bit 1  [read]             # read-only, enforced

pool UartBuffer = Array[64, u8] [count: 8]   # 512 bytes, statically, period
```

Overflow behaviour is part of the type. Register bits know whether they're writable. Pools move allocation decisions to compile time, and `acquire` returns `?T`, so running out is a case you handle, not a crash. Interfaces dispatch through a tag switch with no vtables or heap objects. And the value-only model means no dangling pointers, because there are no pointers to dangle.

## Good to know before you dive in

Tuck is opinionated on purpose, and some of it will feel different:

- **It's young.** It's a work-in-progress compiler with a strong test suite and a small, tracked list of open bugs. Some embedded features (like `[irq_safe]` and `[stack: N]` budgets) are designed and parsed but not fully enforced yet, and concurrency currently runs on a hosted OS while microcontroller support is on the way.
- **A few things look familiar but aren't.** `/` isn't an operator (use `/i` or `/f`). A bare function name is a call, and `:name` is the reference. A payload field can bind to a parameter by type when the names differ. §0 of [LANGUAGE-OVERVIEW.md](LANGUAGE-OVERVIEW.md) collects all of these in one table, so give it a minute before deciding something's broken.
- **Effects are declared everywhere.** `[io]` isn't inferred. It's a bit of extra typing in exchange for signatures that never lie.
- **Interfaces see the whole program.** That's what lets them compile down to plain data, and it also means they aren't meant for runtime plugins.
- **There's usually one way to do a thing.** If you enjoy having many ways to write the same loop, Tuck will feel strict. That's the trade: less freedom, less head scratching.

## Try it

```sh
nim c --hints:off -o:tuck tuck.nim   # build the compiler
./tuck check   file.tuck             # types + effects, no output
./tuck build   file.tuck             # emit and link a binary
./tuck explain TK-TY15               # what a diagnostic means
./tests/run                          # the whole suite
```

Start with the examples that have `fn main`, since those run and are checked for their results. Then try what Tuck is really about: brainstorm a small app, name its big parts, sketch it in a `pending:` block, watch it run empty, and fill it in.
