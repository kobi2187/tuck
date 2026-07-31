# How This Compiler Works

A tour of the Tuck compiler, written for someone who wants to understand how
compilers work in general and is happy to use this one as the worked example.
No prior compiler experience assumed. If you know what a function and a loop
are, you know enough to start.

The short version: a compiler is a **pipeline**. Text goes in one end, and at
every stage it becomes a little more structured and a little more checked,
until it's structured enough to print out as another language. Tuck compiles to
Nim and to Odin, so the last stage happens twice.

```
  your .tuck file
        |
    [ lexer ]        text          ->  tokens
        |
    [ parser ]       tokens        ->  a tree
        |
    [ modules ]      one tree      ->  all the trees it imports
        |
    [ typecheck ]    tree          ->  tree + "this is well-typed"
        |
    [ semantics ]    tree          ->  tree + "the effects add up"
        |
    [ mangle ]       tree          ->  tree with collision-proof names
        |
    [ lowering ]     tree          ->  simpler tree
        |
    [ codegen ]      tree          ->  Nim source / Odin source
        |
  a program you can run
```

Every stage gets its own section below. For each one: what job it does, why a
compiler needs it at all, and which file to open.

---

## Stage 1 — The lexer: text into tokens

**File:** `lexer.nim`

Source code arrives as one long string. `fn main() -> void:` is just 19
characters; nothing about it says "here is a keyword" or "here is a name."

The lexer's job is to chop that string into **tokens** — the words of the
language:

```
fn main() -> void:
```
becomes
```
tkFn  tkIdent("main")  tkLParen  tkRParen  tkArrow  tkIdent("void")  tkColon
```

Why bother with a separate stage? Because every later stage would otherwise
have to re-answer boring questions constantly — "is this whitespace?", "does
this number have a decimal point?", "is this a comment?" Answer them once, and
everything downstream deals in tokens.

Tuck is indentation-sensitive, like Python. So the lexer also emits
`tkIndent` and `tkDedent` tokens when the indentation level changes. That's a
neat trick: it means the parser can treat a block the same way it treats
anything wrapped in brackets, because the "brackets" are now real tokens.

---

## Stage 2 — The parser: tokens into a tree

**Files:** `compiler/parser.nim` (declarations), `compiler/parser_expr.nim`
(expressions), `compiler/parser_type.nim` (types),
`compiler/parser_base.nim` (shared plumbing)

Tokens are a flat list. But programs are **nested** — a function contains
statements, a statement contains expressions, an expression contains more
expressions. The parser builds the tree that mirrors that nesting. It's called
an **AST**: Abstract Syntax Tree.

"Abstract" because it throws away things that don't affect meaning. Parentheses
you wrote for readability, whitespace, comments — none survive. What's left is
pure structure: `2 + 3 * 4` becomes a tree that *knows* the multiply binds
tighter, with no parentheses needed to say so.

The parser is split across several files because the grammar has natural
layers, and they form a one-way dependency chain:

```
parser_base     the shared bits: peek, advance, expect, error reporting
    ^
parser_expr     expressions and patterns (the recursive heart)
    ^
parser_type     type expressions -- int, {a: int}, !str, Seq[int]
    ^
parser          declarations: fn, type, actor, task, the top level
```

Each layer may only use the ones below it. That's not bureaucracy — it's what
keeps the recursion from becoming a knot. When you add syntax, the layer tells
you where it goes.

**Where the AST is defined:** `compiler/ast.nim`. Worth a read, because every
later stage is just "walk this tree and do something."

One design rule worth knowing, because it shows up everywhere: **each language
construct gets its own node kind.** When Tuck added `on select`, it got real
`exkSelect` and `dkSelect` nodes rather than being smuggled in as a `match`
with a fake subject. The clever reuse is always tempting and always costs more
later, because every downstream stage has to learn the trick.

---

## Stage 3 — Modules: finding the rest of the program

**File:** `compiler/modules.nim`

`import time` means the compiler now needs `std/time.tuck` too — and whatever
*that* imports. This stage walks the import graph and loads the whole closure.

There's a performance idea here worth stealing. Checking a program doesn't need
the full *bodies* of everything it imports — it only needs their
**signatures**, the names and types of what they export. So `modules.nim`
keeps a signature index on disk, and `tuck check` loads signatures instead of
parsing entire files. `tuck build` asks for the real bodies, because now it
actually has to emit code for them.

---

## Stage 4 — Typechecking: does this program make sense?

**File:** `compiler/typecheck.nim` (with `typecheck_state.nim`,
`typecheck_util.nim`, `typecheck_flow.nim`)

Here's where a compiler earns its keep. The parser will happily build a tree
for `"hello" + 5`. It's perfectly good *syntax*. It's nonsense *semantically*,
and the typechecker is what says so — before you run the program, rather than
after it crashes.

Tuck uses **bidirectional** typechecking, which is a fancy name for two
cooperating questions:

- **synthesize** — "I have no expectations. What type IS this?"
  (`5` synthesizes `int`.)
- **check** — "I expect a `str` here. Does this fit?"

Most real typecheckers work this way, because pure inference gets expensive and
pure annotation gets tedious. Alternating between the two gets most of the
convenience for much less machinery.

### The interesting part: what does `a.b` mean?

`synthFieldAccess` is the best thing in this compiler to read if you want to
feel how a language actually gets defined. The syntax `a.b` means several
different things in Tuck, and the checker decides which by trying them in a
fixed order:

1. `.ok` / `.err` / `.value` on a fallible value — result introspection
2. `slot.invoke {args}` — calling through a baked function slot
3. `5.ms`, `n.toStr` — postfix application, early path: a literal or plain
   variable receiver inside a function body
4. `Color.Red` — constructing a variant of a sum type
5. `point.x` — an ordinary field read
6. `Pool.acquire`, `Pool.release {v}` — a pool member call
7. `x.describe` — postfix application again, as the fallthrough; plus
   `.fn {args}`, the method form where the receiver is the first parameter and
   the braces fill the rest

**That order is the language rule.** It isn't an implementation detail; it's the
spec. Change the order and you change what programs mean. In the code, each case
is a small proc returning `nil` for "not mine," so the parent function reads as
exactly the list above.

Steps 3 and 7 are worth dwelling on, because they are the *same* operation
reached from two places. Both build the identical node — a call with the
receiver as its argument. They are split only because the ordering forces it:
#3 has to run **before** variant construction and field reads, so `5.ms` is not
mistaken for a field; #7 has to run **after** them, so a genuine field beats a
same-named function. `asPlainField` sits between the two and raises an error if
a field and a function share a name, which is what makes splitting them safe.

Note also that #6 is *not* `module::function` — that is `::`, a different node
kind (`exkQualified`) handled over in `synthCall`, and it never reaches this
proc. What lands here is the dot form for pool members, registered internally
under a dot-joined key (`"Pool.acquire"`). The two namespaces coexist inside
`fnSigs`, so keep the spellings straight: `.` for pool members, `::` for module
calls.

That's a general lesson about compilers: a surprising amount of "language
design" turns out to be *the order in which you try interpretations*.

### Effects

`typecheck.nim` also tracks **effects** — markers like `[io]` on a function
saying "this touches the outside world." A pure function calling an `[io]`
function is an error. It's a type system for side effects, and it means you
can look at a signature and know whether it can print, allocate, or block.

---

## Stage 5 — Semantics: the effect audit

**File:** `compiler/semantics.nim`

A second pass confirming effects add up across the whole program. It runs
**after** typechecking, and the order genuinely matters: typechecking resets
the shared semantic side-table, so if the effect pass ran first, its notes
would be wiped before codegen ever saw them.

This is a recurring theme in compilers — passes share state, and the ordering
constraints between them are real but invisible. When you find one, write it
down. (In this codebase it's written on `checkOrDie` in `tuck.nim`.)

---

## Stage 6 — Mangling: making names safe

**File:** `compiler/mangle.nim`

Tuck compiles *to Nim and Odin*. So what happens if you write a Tuck type
called `Feed`, and Nim also has something called `Feed`? The emitted code binds
the wrong one, and the failure is baffling.

The fix is blunt and effective: rename everything. `Feed` becomes `tuck_Feed`.
Nothing user-written can collide with a target-language symbol, ever.

**But here's the subtlety, and it caused two real bugs in this codebase:**
mangling is about **emitted identifiers only**. It exists to keep generated
*code* from colliding. Anything that isn't an emitted identifier has no
business being mangled.

Error IDs are the example. An error ID like `t/ParseError.Empty` gets hashed
into a number at compile time and printed back to the user in reports. It never
becomes an identifier in the output, so it never had a collision problem. When
the mangled name leaked into it, two things broke at once: `match r.err` stopped
matching (one side mangled, one side not), and error reports started printing
`tuck_ParseError` at users.

The fix was to have nodes remember the name the user wrote (`sourceName` in
`ast.nim`), rather than trying to reconstruct it by stripping prefixes off the
mangled one. **A compiler should keep facts it knows, not re-derive them from
naming conventions later.**

---

## Stage 7 — Lowering: making the tree simpler

**File:** `compiler/lowering.nim`

Lowering rewrites convenient-but-complicated constructs into plain ones, so
codegen has fewer shapes to handle. Two concrete jobs in this compiler:

- **Registry raises become ordinary calls.** `Registry.raise SomeEvent` is a
  pleasant thing to write and an awkward tree to emit — a call whose callee is
  a call whose argument is a field access. Lowering flattens it into a call to
  a plain function named `raise_Registry_SomeEvent`. Codegen then treats it
  like any other call and never learns registries exist.
- **Payload explosion.** Tuck lets you pass a struct where a function declares
  separate parameters, matching them up by name. Lowering does that matching
  and rewrites the call into positional arguments, so codegen just emits
  arguments in order.

Notice the shape of both: something friendly at the source level becomes
something boring before it reaches the emitter. That's the whole idea.

Every backend lowers its **own deep copy** of the tree, because lowering
mutates it in place. Sharing one tree would mean the second backend lowering
already-lowered code.

The general principle: **shrink the language before you emit it.** Every
construct eliminated here is one that each backend doesn't need to know about —
and with two backends, that saving doubles.

---

## Stage 8 — Codegen: printing it out

**Files:** `compiler/codegen.nim` (Nim), `compiler/codegen_odin.nim` (Odin),
`compiler/codegen_common.nim` (the shared bits)

The final stage walks the tree and prints source code in the target language.
It's the least mysterious stage — mostly string building — but there are two
things worth noticing.

**One: the shape of a code generator.** Both backends are built around a big
`case` over node kinds, one arm per kind. Those `case` statements are
deliberately left whole, even though they're long, because Nim errors on a
missing arm. Add a new node kind and the compiler immediately tells you every
backend that hasn't handled it. Splitting the dispatch into smaller pieces would
trade that compile-time guarantee for a silent gap. **Length is not the enemy;
nesting is.** The arms delegate to small named procs; the dispatch stays flat.

**Two: what to share between backends and what not to.** Some things were
copy-pasted identically into both — `errNameFor`, `actorSingletonName` — and
those moved into `codegen_common.nim`. But `genObjectDecl` stayed duplicated,
because Nim spells it `type X = object` and Odin spells it `X :: struct {}`. A
shared abstraction over a genuine difference is worse than two honest copies; it
turns into a template engine nobody can read. **Share the logic, not the
syntax.**

### The decision-table trick

`genFnDecl` in `codegen.nim` has a nice optimization worth reading. A Tuck
decision table compiles one of two ways:

- If every input column has a small enumerable set of values, the whole table
  collapses into a single `case` over one packed integer key. Every combination
  is resolved at compile time and grouped by outcome. Zero comparisons at
  runtime.
- Otherwise, it falls back to an ordinary if/elif chain.

That's a real compiler optimization at a readable scale: **do the work at
compile time so the program doesn't do it at runtime.**

---

## The driver: gluing it together

**File:** `tuck.nim`

The command-line entry point. `checkProgram` shows the whole pipeline in a
dozen lines — load, inject imported types, typecheck, verify effects, refresh
the index, report what's pending.

Tuck has a nice feature for exploratory coding: `pending:` blocks. You declare a
function's signature without a body, and the compiler generates a stub and lists
it as unimplemented. The program still compiles and runs. You can sketch a whole
design in types, run it, then fill in bodies. The PENDING report is that list.

---

## How the modules depend on each other

Dependencies point one way only. Nothing below depends on anything above it:

```
                    ast          the tree everything else talks about
                     |
        +------------+------------+
        |            |            |
   ast_query    resolution     lowering       questions / side-tables / simplification
        |            |            |
        +------------+------------+
                     |
       +-------------+--------------+
       |             |              |
   typecheck     semantics      mangle          the checking and renaming passes
       |             |              |
       +-------------+--------------+
                     |
              codegen_common                    what both backends share
                 /        \
          codegen        codegen_odin           the two emitters
                 \        /
                   tuck.nim                     the driver
```

If you're adding something, this tells you where it goes. A new question about
the tree belongs in `ast_query`. A new check belongs in `typecheck`. A new
emitted construct belongs in both backends — and if you find yourself writing
the same non-syntax logic twice, that's `codegen_common` calling.

---

## Where to start reading

Depending on what you're curious about:

- **"How does a compiler actually work?"** — `lexer.nim`, then
  `compiler/parser_expr.nim`. Small, self-contained, and you can see the tree
  being built.
- **"How does a language get *defined*?"** — `synthFieldAccess` in
  `compiler/typecheck.nim`. Seven meanings for `a.b`, in priority order.
- **"How is code generated?"** — `genFnDecl` in `compiler/codegen.nim`,
  especially the decision-table part.
- **"What does the whole thing do?"** — `checkProgram` in `tuck.nim`.

### A trick worth knowing: exhaustive dispatch as a free check

`compiler/ast_serializer.nim` has no `else` branch anywhere — every `case` over
a node kind handles every kind. That isn't tidiness; it's a cheap correctness
check. Add a node kind to `ast.nim` and the serializer stops compiling until
someone handles it, so the dump always shows whatever the parser actually
built.

The general move: **when a `case` covers an enum, prefer no `else`.** You trade
a one-minute chore whenever the enum grows for a compile error instead of a
silent gap. Codegen does the same thing for the same reason.

## Running it

```bash
./tuck l  file.tuck    # lex     - dump the tokens
./tuck p  file.tuck    # parse   - dump the tree (--ast for JSON)
./tuck ch file.tuck    # check   - typecheck only, no output
./tuck c  file.tuck    # compile - emit source
./tuck b  file.tuck    # build   - emit and compile to a binary
```

Those first two are genuinely useful for learning: run `./tuck l` and `./tuck p`
on a small file and watch text become tokens become a tree.

The test suite is `./run-all-tests.sh` — every `tests/*.nim` plus a CLI smoke
test, behind one pass/fail gate.
