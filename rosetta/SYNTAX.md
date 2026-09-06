# Tuck syntax reference for example authors

Derived from the SOURCE (lexer.nim, compiler/parser*.nim, compiler/ast.nim) on
2026-07-25, plus probes that were actually built and run. Where source and
tuck-spec.md disagree, THIS FILE WINS — it matches the parser.

Scope for this effort: the CORE language. No actors, tasks, select, registers,
pools, arenas, registry, extern, transitions. Those are separately covered.

## Program shape

```tuck
import io

fn main() -> void [io]:
  {text: "hello"} printLine
  return
```

- No top-level statements. A module is declarations; `fn main` runs.
- Indentation only, **spaces** — tabs are a lexical error.
- Comments are `#` to end of line.
- `[io]` is an effect marker on the signature. Pure fns cannot call `[io]` fns.
  Others: `[noalloc] [irqsafe] [unsafe] [mayblock] [stack] [priority]`.

## Calls are postfix — the one call rule

`{payload} fnName`. **`fnName(args)` is a parse error** (the parser says so
explicitly). The payload is offered to the first parameter whole; if it does
not fit, the payload's FIELDS fill parameters by name (subset matching; extra
fields are fine).

```tuck
{text: "hi"} printLine          # struct payload
{value: n} toStr                # ditto
x.double                        # `.name`  — same call, no args
x.scale {factor: 2}             # `.name {args}` — receiver is param 1
5.ms                            # postfix application of fn `ms`
```

Module calls do **not** need the `mod::` prefix when imported and unambiguous.
Write `printLine`, not `io::printLine`. Use `io::printLine` only to
disambiguate a collision. The `import` line is still required.

## Declarations

```tuck
type Point:                 # record
  x: int
  y: int

type Shape:                 # sum type
  | Circle({r: int})
  | Square({side: int})

type Temperature:           # with invariant
  celsius: int
  invariant:
    celsius >= -273

distinct Meters = int       # distinct unit type
fnsig Adder = {a: int, b: int} -> int    # named fn signature
const maxSize = 100
```

- Construct with `{fields} TypeName` — e.g. `{x: 1, y: 2} Point`.
- `fn name({params}) -> Ret [effects]:` — params are a braced struct.
- **A fallible fn (returning `!T`) MUST be marked `[io]`.** Verified:
  `fn parseInt({text: str}) -> !int` without `[io]` is an Effect Error —
  "fallible functions must be marked [io]; pure functions are total".
  The pure core is total by design.
- Generics: `fn at[T]({items: Seq[T], index: int}) -> T`.
- `fn inline name(...)` is a codegen hint.
- `pending:` block declares typed holes that compile AND run (stubs).

## Statements / expressions

```tuck
let x = 5                  # immutable
var y = 0                  # mutable
y = y + 1
y += 1                     # also -= *= /=

if a < b:
  ...
elif a == b:               # elif works (added 2026-07-26)
  ...
else:
  ...

match shape:               # arms are `pattern: value`
  Circle: 1
  Square: 2
  _: 0

for i in 0 ..< 10:         # exclusive range
for i in 1 .. 10:          # inclusive range (SPACES around `..` required)
for item in items:
for idx, item in items:    # index + value
for b != 0:                # while-style: a real CONDITION goes here.
                           # (Do not write the literal word `cond` — it would
                           # be read as a variable named cond.)
loop:                      # infinite
  break
continue

return value
```

`decision` tables for tabular logic (rows use `->`, unlike match's `:`):

```tuck
decision route({priority: Priority, encrypted: bool}) -> int:
  | high  true  -> 1
  | high  false -> 2
  | low   _     -> 3
```

## Operators

Precedence, low to high: `..`/`..<` (-2), `and`/`or` (-1), comparisons
`== != < > <= >=` (0), `+ -` (1), `* / %` (2).

**Postfix calls bind TIGHTER than operators.** `x + y sys::exit` parses as
`x + (y sys::exit)`. Parenthesize when mixing.

Other: `not`, unary `-`, `!T` result type, `?T` optional.

**Correction (2026-07-25):** an earlier version of this file documented `expr?`
as error propagation. **That does not exist.** `tkQuestion` appears only in
type syntax (`?T`/`!T`), never in the expression parser — `{a, b} divide?` is
a parse error. There is currently NO verified `!T` → `T` unwrap idiom; the
readable-under-`if r.ok` narrowing described in TOUR.md is the only route.

## Data reshaping (all compile-time, zero cost)

```tuck
let all = input                          # the whole incoming payload
let ctx = {episode, prefs} merge         # flatten into one struct
let n = track alias(trackId: id, title: name)   # rename fields
let f = x bake {op: :plus}               # partial application; :name is a fn ref
```

## Collections

```tuck
let xs = [3, 1, 4]        # list literal
xs.len                    # length — works on Seq AND on str
xs[i]                     # indexed read
xs[i] = v                 # indexed write (var only)
```

**`xs[i]` sugar lowers to `seq::at`/`setAt`, so a file using brackets MUST
have `import seq`** or it fails with a raw Nim error instead of a Tuck one.

## Known gaps — DO NOT write these

- ~~No `elif`~~ — **FIXED 2026-07-26.** `elif` chains now parse.
- **No growable sequences.** `acc = acc + [x]` typechecks but fails to build.
  No `push`/`append`. Use fixed-size arrays with `xs[i] = v`.
- **No `if` expression form.** `let x = if c: a else: b` is a parse error.
- **No string indexing and no char type.** `s[0]` / `seq::at` on a str is a
  type error. No split/slice/parse-int in the stdlib.
- `fnName(args)` paren-call form (postfix only).

## Inventing functions

Examples MAY call functions that do not exist yet — that is how stdlib gaps get
discovered. Prefer declaring them as typed holes so the file still compiles:

```tuck
pending:
  fn sortAscending({items: Seq[int]}) -> Seq[int]
```

Name them the way Tuck would: postfix-friendly, struct payloads, no `get`
prefix noise.
