# web-downloader — what the language made easy, and what it fought

Written 2026-09-15 against `HEAD`. `downloader.tuck` **type-checks**
(`tuck ch` → `OK`); the only remaining output is the size report, discussed
below. It is not runnable — the syscall edge is `extern` against a `netdl.h`
that does not exist — which is deliberate: the point was to find out what the
language can and cannot *say*.

## What came out beautifully

These needed no workaround at all, and each replaced something a downloader
normally hand-rolls:

| feature | what it replaced |
|---|---|
| `resources: conn [cap: 8]` | the connection pool, the parallelism limit, AND the leak report. `on_full: absent` means a full table makes a chunk *wait* rather than fail — exhaustion as absence is exactly right here. |
| `task` + `on select` | a per-socket stall deadline that races the read. No watchdog thread, no timer wheel. |
| `actor Progress` | the byte counter. No lock, no atomic, and the compiler will not let anything else write it. |
| `registry Download` | every observable event in one declaration. Nothing prints from inside the download; the display is four handlers reading events. |
| `decision recover(...)` | the retry policy, as a table, because it *is* a table. |
| `invariant` on `Chunk` | the range arithmetic. `have <= (last - first) + 1` is the bug this class of program always has. |
| `defer: finish fd, conn` | the close path, including the error paths. |

The `[resource: conn]` effect propagating to callers is a genuinely nice
touch: anything that can spend a connection says so in its own signature, so
the budget is visible at every level rather than buried in the pool.

## Where it fought — ranked by how much it cost

### 1. A registry handle cannot give back its raw descriptor

The worst one, and the same gap as #45's DMA case.

`acquire` returns an opaque `ConnHandle`. Every syscall needs the `int`, and
`on select`'s `read <fd>` needs it too. There is no sanctioned way from handle
to descriptor, so the program carries both:

```tuck
let sock = {host: host, port: port} dial   # the raw fd, kept by hand
let fd = acquire sock, conn                # the registry's handle
```

`examples/47` states the intended property outright — the raw fd *"exists
between the extern's return and this line and nowhere else"*. That holds for a
resource you only ever close. It does not hold for one you **read from**, which
is most of them. A socket, a file, a device node: the whole point is to do IO
on it after registering it.

Keeping both defeats the guarantee: the raw `sock` outlives the handle's
tenancy and nothing stops a stale use of it.

**Wanted:** a checked accessor — `fd.value.raw`, or `read fd.value` teaching
`select` about handles — so the descriptor is reachable *through* the tenancy
check rather than around it.

### 2. A `select` arm is one expression on one line

An arm cannot have a block body. The natural read arm here is eight
statements — take bytes, detect close, write at offset, advance two counters,
tell the actor, raise the event — and none of that can live in the arm.

It became a helper, `sip`, which is a decomposition the language wants anyway,
so this is half a feature and half a limit. But the forced shape leaks:

- `sip` cannot *branch* the loop. A closed peer has to be signalled by
  returning `need`, so the loop condition happens to end. That is a trick, and
  it reads like one.
- Two values wanted updating (`at` and `got`); a helper returns one, and Tuck
  has no destructuring (§2.2). `at` became `base + got`, derived rather than
  tracked — which is genuinely better, but it was the constraint that found
  it, not the design.

**Wanted:** an indented block body for a select arm. The actor form already
takes one; the task form does not.

### 3. `acquire`'s `?T` does not compose with `read <fd>`

`read` takes a bare name, not an expression, so `read fd.value` is a parse
error (`Expected Arrow here, found .`). Since `acquire` *always* answers `?T`,
every registry-backed select needs an intermediate binding. Two features that
are obviously meant to be used together do not fit.

### 4. No expression can be wrapped across lines

Indentation is structure, so a continuation line must be a 2-space multiple —
which forbids the usual alignment under an opening brace:

```tuck
let req = {url: job.url, verb: Method.Get, headers: hdrs,
           body: [], timeoutMs: 30_000} fetch      # TK-LX06
```

Any payload with more than about three fields exceeds 80 columns and has to be
split into `let` bindings. That is often an improvement; it is occasionally
just noise. It cost three rewrites here.

**Wanted:** continuation lines exempt from the indent-width rule when an
opening bracket is unclosed — the one place where indentation is *not*
structure.

### 5. A call inside a payload must be bound first (TK-PA13)

```tuck
| read sock -> {}: got = {..., need: {c} remaining} sip   # refused
```

Combined with (2) — an arm is one expression — this bites twice: the arm may
not contain a block *and* may not compose a call inside its payload, so
anything non-trivial needs bindings that must live outside the arm.

### 6. The size budget counts comment lines

Measured directly: a function with one `return` and nine comment lines reports
*"spans 11 lines (limit 8)"*.

In a codebase whose house style is heavy explanatory comments — which this one
emphatically is — the budget penalises the thing it wants. The workaround is to
move commentary above the signature, which is often the wrong place for it: a
comment about one step belongs at that step.

**Wanted:** count statements, not lines. Cheap to fix and it removes a standing
incentive against documenting.

### 7. A fire-and-forget spawn of a fallible task is an unhandled result

`{...} pull discard` — because a spawn drops the task's answer, and under
`strict` a dropped `?int` is an error. `discard` is honest here (the actor
carries the outcome), but "spawn N workers" is the ordinary shape and it should
probably not need the word.

## Smaller notes

- **`while` does not exist**, and the diagnostic says so and names the
  replacement (`for <cond>:`). Perfect error — cost nothing.
- **`/` is not an operator**; `/i` and `/f` name the arithmetic. The error
  explains why. Right call, and the message teaches it.
- **`from` is a reserved word** in a backend, caught at the parameter with a
  clear message.
- **Registry handlers take an effects bracket** (`on Download.Advanced(...)
  [io]:`) — not obvious from the examples, since none of them do IO. Worth a
  line in the spec: a display handler is the natural place for `[io]`.

## The one thing I could not express at all

**Awaiting a specific set of tasks.** Binding one task's result awaits that
task; there is no way to await *these eight*. The program works around it with
an actor predicate (`waitUntil {pred: :complete}`), which is arguably nicer —
progress is the real completion condition, not task exit.

But it only works because the chunks happen to have a shared numeric total. A
downloader that wanted "all eight finished, however they ended" would have to
count completions in the actor by hand. Combined with #55 (a task's await
drives the whole scheduler until *everything* finishes), the task-group story
is the least finished part of the concurrency model.
