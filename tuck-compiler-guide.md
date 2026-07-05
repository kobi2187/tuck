# Tuck Compiler — Implementation Guide

This guide explains how the compiler works from the ground up. No prior compiler
experience assumed. We go in the order you actually build things.

---

## Part 1 — The Lexer (Tokenizer)

### What a Lexer Does

The raw source file is just a string of characters. The lexer's job is to break
that string into a flat sequence of **tokens** — labelled chunks that the parser
can reason about.

```
"fn add({a: int}) -> int:\n  a + 1"

→ [TkFn, TkIdent("add"), TkLParen, TkLBrace, TkIdent("a"), TkColon,
   TkIdent("int"), TkRBrace, TkRParen, TkArrow, TkIdent("int"), TkColon,
   TkIndent, TkIdent("a"), TkPlus, TkIntLit("1"), TkDedent, TkEof]
```

The parser never sees raw characters. It only sees tokens. This division of labour
is important — it keeps the parser simple.

### Token Types

Define these as a Nim enum. Every possible "thing" in the language gets one entry:

```nim
type TkKind = enum
  # Literals
  TkIntLit, TkFloatLit, TkStrLit, TkBoolLit

  # Identifiers
  TkLoIdent    # foo_bar (lowercase-starting)
  TkUpIdent    # FooBar  (uppercase-starting)

  # Keywords — always check these BEFORE TkLoIdent
  TkFn, TkLet, TkVar, TkIf, TkElif, TkElse
  TkFor, TkIn, TkMatch, TkReturn, TkType
  TkObject, TkMixin, TkInterface, TkActor, TkTask
  TkPending, TkOn, TkSelect, TkRegistry
  TkDecision, TkPool, TkArena, TkRegister
  TkWhen, TkDistinct, TkBake
  TkAnd, TkOr, TkNot, TkTrue, TkFalse, TkNone

  # Punctuation
  TkDot        # .
  TkDotDot     # ..
  TkArrow      # ->
  TkFatArrow   # =>
  TkColon      # :
  TkComma      # ,
  TkPipe       # |
  TkQuestion   # ?
  TkBang       # !
  TkBangQuestion  # !?
  TkColonColon # ::  (function reference :add)
  TkPlus, TkMinus, TkStar, TkSlash, TkPercent
  TkEq, TkNeq, TkLt, TkGt, TkLte, TkGte
  TkAssign     # =

  # Grouping
  TkLParen, TkRParen    # ( )
  TkLBrace, TkRBrace    # { }
  TkLBracket, TkRBracket  # [ ]

  # Indentation (the special ones)
  TkIndent     # one level deeper
  TkDedent     # one level shallower (can emit multiple in a row)
  TkNewline    # end of a logical line

  TkEof        # end of file
```

Each token also carries its value (for literals and identifiers) and its source
position (line, column) for error messages:

```nim
type Token = object
  kind:   TkKind
  value:  string      # the raw text, for literals and identifiers
  line:   uint16
  col:    uint16
```

### The Indentation Problem

This is the only hard part of the lexer. Python, Nim, and Tuck are all
indentation-sensitive. The trick is to handle it entirely in the lexer so the
parser never thinks about whitespace at all.

The lexer maintains an **indent stack** — a stack of column numbers representing
the indentation levels currently open:

```nim
var indentStack: seq[int] = @[0]  # column 0 is always the base
```

The rule runs at the **start of every new line**:

```
1. Count the spaces at the start of the line (tabs = hard error, stop immediately)
2. Compare the count to the TOP of the indentStack

   count > top  →  push count onto stack, emit ONE TkIndent
   count == top →  emit nothing (same level, just continue)
   count < top  →  pop the stack, emit ONE TkDedent per pop,
                   until the top equals count.
                   If count doesn't match ANY level in the stack → error.
```

Example:

```
col: 0123456789

fn foo():        ← base level 0, stack: [0]
  let x = 5     ← indent to 2, stack: [0, 2], emit TkIndent
  if x > 3:     ← same level 2, emit nothing
    return x    ← indent to 4, stack: [0, 2, 4], emit TkIndent
  let y = 1     ← dedent to 2, pop 4, stack: [0, 2], emit TkDedent
fn bar():        ← dedent to 0, pop 2, stack: [0], emit TkDedent
```

Blank lines and comment-only lines are **ignored** for indentation purposes —
they don't emit TkNewline or affect the indent stack at all.

### The Full Lexer Loop

```nim
type Lexer = object
  src:         string
  pos:         int         # current character position
  line:        uint16
  col:         uint16
  indentStack: seq[int]
  tokens:      seq[Token]  # output — the flat list

proc lex(src: string): seq[Token] =
  var l = Lexer(src: src, pos: 0, line: 1, col: 0,
                indentStack: @[0])

  while l.pos < l.src.len:
    # At the start of each line, handle indentation
    if l.col == 0:
      l.handleIndent()

    let ch = l.src[l.pos]

    # Skip horizontal whitespace (inside a line)
    if ch == ' ':
      l.advance(); continue

    # Skip comments
    if ch == '#':
      while l.pos < l.src.len and l.src[l.pos] != '\n':
        l.advance()
      continue

    # Newline
    if ch == '\n':
      # Skip blank lines — don't emit TkNewline for them
      if l.tokens.len > 0 and l.tokens[^1].kind != TkNewline:
        l.emit(TkNewline)
      l.advance()
      l.line += 1
      l.col = 0
      continue

    # Tab = hard error
    if ch == '\t':
      error(l, "Tabs are not allowed. Use spaces.")

    # Two-character tokens (check before single-char)
    if l.peek2() == "..": l.emit2(TkDotDot); continue
    if l.peek2() == "->": l.emit2(TkArrow);  continue
    if l.peek2() == "::": l.emit2(TkColonColon); continue
    if l.peek2() == "!?": l.emit2(TkBangQuestion); continue
    if l.peek2() == "==": l.emit2(TkEq);  continue
    if l.peek2() == "!=": l.emit2(TkNeq); continue
    if l.peek2() == "<=": l.emit2(TkLte); continue
    if l.peek2() == ">=": l.emit2(TkGte); continue

    # Single-character tokens
    case ch
    of '.': l.emit1(TkDot)
    of ':': l.emit1(TkColon)
    of ',': l.emit1(TkComma)
    of '|': l.emit1(TkPipe)
    of '?': l.emit1(TkQuestion)
    of '!': l.emit1(TkBang)
    of '+': l.emit1(TkPlus)
    of '-': l.emit1(TkMinus)
    of '*': l.emit1(TkStar)
    of '/': l.emit1(TkSlash)
    of '%': l.emit1(TkPercent)
    of '<': l.emit1(TkLt)
    of '>': l.emit1(TkGt)
    of '=': l.emit1(TkAssign)
    of '(': l.emit1(TkLParen)
    of ')': l.emit1(TkRParen)
    of '{': l.emit1(TkLBrace)
    of '}': l.emit1(TkRBrace)
    of '[': l.emit1(TkLBracket)
    of ']': l.emit1(TkRBracket)

    # String literals
    of '"': l.lexString()

    # Numbers
    of '0'..'9': l.lexNumber()

    # Identifiers and keywords
    of 'a'..'z', '_': l.lexLoIdent()
    of 'A'..'Z':      l.lexUpIdent()

    else:
      error(l, "Unexpected character: " & ch)

  # End of file: close any open indent levels
  while l.indentStack.len > 1:
    l.indentStack.del(l.indentStack.high)
    l.emit(TkDedent)

  l.emit(TkEof)
  return l.tokens
```

### Keyword Detection

Identifiers are lexed first as raw strings, then checked against a keyword table.
This is simpler than trying to match keywords character by character:

```nim
const keywords = {
  "fn": TkFn, "let": TkLet, "var": TkVar,
  "if": TkIf, "elif": TkElif, "else": TkElse,
  "for": TkFor, "in": TkIn, "match": TkMatch,
  "return": TkReturn, "type": TkType,
  "object": TkObject, "mixin": TkMixin,
  "actor": TkActor, "task": TkTask,
  "on": TkOn, "select": TkSelect,
  "registry": TkRegistry, "decision": TkDecision,
  "pending": TkPending, "when": TkWhen,
  "distinct": TkDistinct, "bake": TkBake,
  "and": TkAnd, "or": TkOr, "not": TkNot,
  "true": TkTrue, "false": TkFalse, "none": TkNone,
}.toTable()

proc lexLoIdent(l: var Lexer) =
  let start = l.pos
  while l.pos < l.src.len and (l.src[l.pos].isAlphaNumeric or l.src[l.pos] == '_'):
    l.advance()
  let word = l.src[start ..< l.pos]
  let kind = keywords.getOrDefault(word, TkLoIdent)
  l.emitValue(kind, word)
```

### What the Lexer Produces

The output of the lexer is a single flat `seq[Token]`. This is the **only** input
the parser receives. The parser maintains a cursor (an integer index) into this
sequence. Peeking at the next token is `tokens[cursor]`. Consuming it is
`cursor += 1`. That's the whole interface.

---

## Part 2 — The Parser and npeg

### What the Parser Does

The parser takes the flat `seq[Token]` and recognises structure. It answers
questions like: "is this a function declaration? Is this an expression? What's
the right-hand side of this assignment?"

In most compilers the parser builds an **Abstract Syntax Tree (AST)** — a tree
of nodes representing the program's structure. In Tuck we skip that step and
build the IR directly during parsing. This is possible because npeg lets you run
Nim code (action blocks) as each grammar rule matches.

### How npeg Works

npeg compiles your grammar to Nim code **at compile time**. There is no
interpreter, no runtime regex engine. The generated Nim code runs as fast as a
hand-written recursive descent parser.

The key ideas:

**Rules** are named patterns that match a sequence of tokens:
```nim
grammar Tuck:
  fnDecl <- TkFn ~ ident ~ TkLParen ~ params ~ TkRParen ~
            TkArrow ~ typeExpr ~ TkColon ~ block
```

**Action blocks** are Nim code that fires when a rule matches:
```nim
  fnDecl <- TkFn ~ >ident ~ TkLParen ~ params ~ TkRParen ~
            TkArrow ~ >typeExpr ~ TkColon ~ block:
    # This code runs when fnDecl matches.
    # capture[0] = the function name (from >ident)
    # capture[1] = the return type  (from >typeExpr)
    ir.add(IRNode(kind: irFnDef, fnName: capture[0], retType: capture[1]))
```

The `>` prefix captures a matched substring. Action blocks write directly into
your IR. No intermediate tree.

### The Tension: npeg Parses Strings, Lexer Produces Tokens

There's a practical issue: npeg is designed to match characters or strings, but
after lexing you have a sequence of `Token` objects, not a string.

There are two approaches:

**Option A — Run npeg on the raw source string.**
Skip the separate lexer entirely. Write the npeg grammar to handle whitespace,
indentation, and everything else directly. The indentation tracking happens inside
npeg action blocks.

This is technically possible but indentation-sensitive parsing inside a PEG
grammar is genuinely painful — you need to thread the indent stack through every
rule that might cross an indentation boundary.

**Option B — Hand-write a recursive descent parser that consumes tokens.**
Use npeg only for the lexer (matching character patterns to produce tokens), then
write a simple recursive descent parser by hand that consumes the `seq[Token]`.

This is the practical choice. A recursive descent parser for Tuck is not large —
maybe 600-800 lines — because the grammar is unambiguous and clean. Each grammar
rule becomes one Nim procedure. `parseFnDecl`, `parseExpr`, `parseBlock`, etc.

The key advantage: error messages are completely in your control. You know exactly
which token you expected and which you got:

```nim
proc expect(p: var Parser, kind: TkKind): Token =
  if p.current().kind != kind:
    error(p, "Expected " & $kind & " but got " & $p.current().kind &
          " at line " & $p.current().line)
  result = p.current()
  p.advance()
```

**Recommendation: Use npeg for the lexer's character-level pattern matching,
write a hand-rolled recursive descent parser for the token-level parsing.**

npeg is excellent for patterns like "a string literal is a quote, followed by any
non-quote characters, followed by a quote." It's awkward for "a block is a
newline, an indent token, one or more statements, then a dedent token" when that
indent token was emitted by stateful logic.

### Recursive Descent — The Pattern

Every grammar rule becomes a `proc`. Procs call each other. The call stack IS the
parse stack. No explicit stack management needed.

```nim
type Parser = object
  tokens:  seq[Token]
  cursor:  int
  ir:      seq[IRNode]   # we write directly here

proc current(p: Parser): Token = p.tokens[p.cursor]
proc peek(p: Parser, offset = 1): Token = p.tokens[min(p.cursor + offset, p.tokens.high)]
proc advance(p: var Parser): Token =
  result = p.current()
  p.cursor += 1

proc parseFnDecl(p: var Parser): NodeIdx =
  p.expect(TkFn)
  let name = p.expect(TkLoIdent).value
  p.expect(TkLParen)
  let params = p.parseParams()
  p.expect(TkRParen)
  p.expect(TkArrow)
  let retType = p.parseTypeExpr()
  let effects = p.parseEffects()   # optional [io, no_alloc]
  p.expect(TkColon)
  let body = p.parseBlock()
  # Write directly into the IR, return its index
  result = p.emitNode(IRNode(
    kind:    irFnDef,
    fnName:  name,
    retType: retType,
    effects: effects,
    body:    body,
    span:    (line: p.current().line, col: p.current().col)
  ))

proc parseBlock(p: var Parser): NodeIdx =
  p.expect(TkNewline)
  p.expect(TkIndent)
  var stmts: seq[NodeIdx]
  while p.current().kind != TkDedent and p.current().kind != TkEof:
    stmts.add(p.parseStmt())
  p.expect(TkDedent)
  result = p.emitNode(IRNode(kind: irBlock, stmts: stmts))
```

The parser builds the IR in one pass over the token stream. When it returns, you
have a flat `seq[IRNode]` with index-based references between nodes.

---

## Part 3 — The Flat IR and How to Navigate It

### Why Flat?

Traditional compilers use pointer-based trees. Each node has fields that are
pointers to child nodes. This is natural but has real costs:

- Serialising a pointer tree (for the cache) requires pointer remapping
- Cache locality is poor — each node is a separate heap allocation
- You can't do simple `for node in ir` scans

A flat `seq[IRNode]` solves all three. Nodes reference each other by index.
Serialisation is just `msgpack(ir)`. Scanning is a plain loop.

### The Index-Based Tree

Consider this Tuck code:
```tuck
fn double({n: int}) -> int:
  n * 2
```

The IR might look like:
```
ir[0] = IRNode(kind: irName, name: "n", span: ...)
ir[1] = IRNode(kind: irConst, constVal: "2", constType: "int", span: ...)
ir[2] = IRNode(kind: irCall, callee: "*", args: [0, 1], span: ...)
ir[3] = IRNode(kind: irBlock, stmts: [2], span: ...)
ir[4] = IRNode(kind: irFnDef, fnName: "double",
               params: [("n", "int")], retType: "int",
               body: 3, span: ...)
```

`ir[4].body` is the integer `3`, which is an index into `ir`. To get the body
node: `ir[ir[4].body]`. To walk a block's statements:

```nim
let blockNode = ir[fnNode.body]
for idx in blockNode.stmts:
  let stmt = ir[idx]
  # process stmt
```

That's the whole model. No pointer chasing, no heap allocation per node.

### Emitting Nodes

The parser builds the IR by appending to a `seq[IRNode]` and returning the
index of the node it just added:

```nim
proc emitNode(p: var Parser, node: IRNode): NodeIdx =
  p.ir.add(node)
  result = NodeIdx(p.ir.high)  # index of the node we just added
```

Because nodes are appended in order, and children are always emitted before
parents (the parser emits leaves first, then the parent that references them),
the tree is naturally stored bottom-up. This means you can walk it in forward
order and always encounter children before parents — useful for the checker.

### Scanning the IR

Two kinds of scans:

**Linear scan — for pass 1 (signature collection):**
```nim
proc collectSignatures(ir: seq[IRNode], sigs: var Table[string, FnSig]) =
  for node in ir:
    if node.kind == irFnDef:
      sigs[node.fnName] = FnSig(
        params:  node.params,
        retType: node.retType,
        effects: node.effects
      )
```

Simple, fast, O(n). Just walk every node, ignore everything except the kinds
you care about.

**Tree walk — for pass 2 (body checking):**

To check a function body you need to walk its sub-tree. Because children have
lower indices than parents, you can either recurse downward via indices, or
collect all nodes belonging to a subtree first.

The recursive approach is simplest:

```nim
proc checkExpr(ir: seq[IRNode], idx: NodeIdx, ctx: var CheckCtx): Shape =
  let node = ir[idx]
  case node.kind
  of irConst:
    return Shape(fields: {"value": node.constType}.toTable())
  of irName:
    return ctx.scope.lookup(node.name)  # look up in current scope
  of irCall:
    let argShape = checkExpr(ir, node.args, ctx)
    let fn = ctx.sigs[node.callee]
    if not argShape.satisfies(fn.params):
      error(node.span, "Shape mismatch: ...")
    return fn.retType.toShape()
  of irBlock:
    var lastShape: Shape
    for stmtIdx in node.stmts:
      lastShape = checkExpr(ir, stmtIdx, ctx)
    return lastShape
  # ... etc
```

---

## Part 4 — Semantic Annotation: The Real Problem

### What "Annotation" Means

After pass 1 collects signatures and pass 2 checks bodies, you want to enrich
the IR nodes with semantic information — the resolved type of each expression,
which concrete function each call resolves to, which variant a match arm handles.

This enriched IR is what the emitter reads. Without it, the emitter has to redo
type resolution at emit time, which means duplicating the checker logic.

The naive solution is to add optional fields to every `IRNode`:

```nim
type IRNode = object
  span: ...
  case kind: IRKind
  # ... structural fields ...
  # Semantic annotation, filled in by pass 2:
  resolvedType:   string          # "" means not yet annotated
  resolvedCallee: string          # for irCall: the exact fn that was chosen
```

This works but has a problem: Nim's `case object` (tagged union) doesn't allow
fields outside the `case`. Fields that live in `of` branches can't be shared.

### The Clean Solution: A Parallel Annotation Table

Keep the IR nodes exactly as they are — pure structure, no semantic info.
Store the annotations separately, keyed by `NodeIdx`:

```nim
type Annotation = object
  resolvedType:    string              # the shape/type of this expression
  resolvedCallee:  string              # for calls: which exact fn matched
  resolvedVariant: string              # for match arms
  effectsInferred: seq[string]         # propagated effect markers

type Annotations = Table[NodeIdx, Annotation]
```

Pass 2 builds this table as it checks. The emitter takes both `ir` and
`annotations` as inputs:

```nim
proc emit(ir: seq[IRNode], annotations: Annotations): string =
  # for any node that needs semantic info:
  let ann = annotations.getOrDefault(nodeIdx)
  # use ann.resolvedCallee, ann.resolvedType, etc.
```

This keeps the IR clean and immutable. The annotations are a separate product of
the checker. You can cache them separately, discard them and recheck, or diff
them between runs.

### Fast Retrieval

`Table[NodeIdx, Annotation]` in Nim is a hash table. Lookup by `NodeIdx` (which
is just an `int32`) is O(1). For a file with 1000 IR nodes, the table holds at
most 1000 entries. Lookup is essentially free.

For the cache, you serialise both `ir` and `annotations` into the same msgpack
envelope. On a cache hit, you deserialise both and skip the checker entirely.

### What Gets Annotated

Not every node needs an annotation. Only nodes whose semantic information isn't
already fully determined by their structure:

| Node Kind | What Gets Annotated |
|---|---|
| `irCall` | `resolvedCallee` — which function matched the arg shape |
| `irName` | `resolvedType` — what shape does this variable have |
| `irIf` | `resolvedType` — the unified type of all branches |
| `irMatch` | `resolvedType` — same |
| `irBlock` | `resolvedType` — type of the last expression |
| `irFnDef` | `effectsInferred` — propagated up from callees |
| `irMutate` | `resolvedCallee` — which set-function matched |

Literals (`irConst`), struct literals (`irStruct`), and type declarations
(`irTypeDecl`) don't need annotation — their types are fully determined by their
structure.

---

## Part 5 — Bidirectional Typing

### The Problem

Given this expression:
```tuck
let x = {a: 5, b: someFunc {10}}
```

To know the type of `x`, you need to know the type of `{a: 5, b: someFunc {10}}`.
To know that, you need to know the return type of `someFunc`. `someFunc` is in
the signature table from pass 1. So you look it up — great.

But what about:
```tuck
let x = if condition: {value: 5} else: {value: 10}
```

The type of `x` depends on both branches being the same shape. You need to check
both branches and verify they agree.

And what about:
```tuck
processAll {items: data.filter {pred}}
```

`processAll` requires `{items: Seq[Episode]}`. Does `data.filter {pred}` produce
that? To know, you need to check `filter`'s return type against what `processAll`
expects. This is "pushing a known type downward into an expression."

### Two Directions

**Synthesis (bottom-up):** Given an expression with no context, figure out what
type it produces. "What type does this expression have?"

**Checking (top-down):** Given an expression AND an expected type, verify the
expression produces something compatible. "Does this expression satisfy this
expected type?"

```nim
# Synthesise: figure out what type idx produces
proc synth(ir: seq[IRNode], idx: NodeIdx,
           ctx: var CheckCtx, ann: var Annotations): Shape

# Check: verify idx produces something compatible with expected
proc check(ir: seq[IRNode], idx: NodeIdx, expected: Shape,
           ctx: var CheckCtx, ann: var Annotations)
```

These two procs call each other. The combination handles almost all cases cleanly.

### The Rules

**Literals — always synthesise:**
```nim
of irConst:
  result = singleFieldShape("value", node.constType)
  ann[idx] = Annotation(resolvedType: result.toStr())
```

**Variable reference — synthesise from scope:**
```nim
of irName:
  result = ctx.scope[node.name]  # looked up from let/var bindings above
  ann[idx] = Annotation(resolvedType: result.toStr())
```

**Function call — synthesise args, then check against fn signature:**
```nim
of irCall:
  # Synthesise the argument shape (bottom-up)
  let argShape = synth(ir, node.args, ctx, ann)

  # Look up all functions with this name
  let candidates = ctx.sigs.getAll(node.callee)

  # Find ones where argShape is a superset of their required params
  let matches = candidates.filterIt(argShape.satisfies(it.params))

  if matches.len == 0:
    error(node.span, "No function '" & node.callee & "' accepts shape " & $argShape)
  if matches.len > 1:
    error(node.span, "Ambiguous: multiple functions match. Qualify the call.")

  ann[idx] = Annotation(resolvedCallee: matches[0].name,
                        resolvedType: matches[0].retType.toStr())
  result = matches[0].retType
```

**`if` expression — check both branches, unify:**
```nim
of irIf:
  # If we have an expected type from context, push it down (top-down)
  # Otherwise synthesise each branch and check they agree
  var branchTypes: seq[Shape]
  for branch in node.branches:
    if branch.cond.isSome:
      check(ir, branch.cond.get, boolShape, ctx, ann)
    branchTypes.add(synth(ir, branch.body, ctx, ann))
  let unified = unify(branchTypes)
  if unified.isNone:
    error(node.span, "If branches produce incompatible shapes")
  ann[idx] = Annotation(resolvedType: unified.get.toStr())
  result = unified.get
```

**Function body — check against declared return type:**
```nim
of irFnDef:
  # The return type is known from pass 1 (it's required on the signature)
  let declared = ctx.sigs[node.fnName].retType
  # Push the declared type DOWN into the body (top-down checking)
  check(ir, node.body, declared.toShape(), ctx, ann)
```

This is the key insight of bidirectional typing: **when you know the expected
type (because it's declared), push it down. When you don't, synthesise bottom-up.**
The combination resolves almost everything without full Hindley-Milner inference.

### Handling Scope

As you walk into a block, new `let` and `var` bindings come into scope. As you
leave the block, they go out of scope. Use a simple stack of tables:

```nim
type Scope = seq[Table[string, Shape]]  # stack of binding maps

proc push(s: var Scope) = s.add(initTable[string, Shape]())
proc pop(s: var Scope)  = s.del(s.high)
proc define(s: var Scope, name: string, shape: Shape) = s[^1][name] = shape
proc lookup(s: Scope, name: string): Shape =
  for i in countdown(s.high, 0):
    if name in s[i]: return s[i][name]
  error("Undefined: " & name)
```

When the checker encounters `irLet` or `irVar`:
1. Synthesise the value's shape
2. `scope.define(node.bindName, valueShape)`
3. Record the annotation

---

## Part 6 — Putting It All Together

### The CheckCtx

All the state the checker needs, bundled:

```nim
type CheckCtx = object
  ir:          seq[IRNode]          # the full IR (read-only during checking)
  sigs:        Table[string, seq[FnSig]]  # pass 1 output, all signatures
  shapes:      Table[string, Shape]       # pass 1 output, all type shapes
  graphs:      Table[string, TransGraph]  # pass 1 output, transition graphs
  scope:       Scope                # current variable bindings
  currentFn:   string               # for error messages
  errors:      seq[CompileError]    # collected, not thrown
```

### The Complete Flow for One Function

```
parseFnDecl()           →  ir[N] = IRNode(kind: irFnDef, ...)
                           ir[N-k..N-1] = body nodes

pass1 linear scan       →  sigs["myFn"] = FnSig(params, retType, effects)
                           hash the node → check cache
                           HIT: load annotation from cache, skip pass2
                           MISS: continue

pass2 checkFnDef(N)     →  push scope
                           for each param: scope.define(name, shape)
                           declared = sigs["myFn"].retType.toShape()
                           check(ir, body, declared, ctx, ann)
                           pop scope

annotation table        →  ann[N] = Annotation(effectsInferred: [...])
                           ann[expr] = Annotation(resolvedType: ...)  for each expr

cache write             →  envelope = {ir[N..body], ann[N..body]}
                           key = merkleHash(ir[N])
                           cache[key] = msgpack(envelope)

emitter                 →  emitFnDef(ir[N], ann)
                           → "proc myFn(args): retType = ..."
```

### Error Collection

The checker never throws or panics. Every error goes into `ctx.errors`:

```nim
proc typeError(ctx: var CheckCtx, span: Span, msg: string) =
  ctx.errors.add(CompileError(span: span, message: msg))

# After checking a function body, if there were errors,
# log them and move on to the next function.
# Don't let one bad function block checking of others.
```

At the end of the full pass, if `ctx.errors.len > 0`, print all errors and stop.
Don't emit anything if there are errors.

### The Scope of What You're Building

To make this concrete, here are rough line counts for each component:

| Component | Rough Size | Notes |
|---|---|---|
| Lexer | ~300 lines | The indent logic is 50 of those |
| Parser (recursive descent) | ~600 lines | One proc per grammar rule |
| Pass 1 linear scan | ~100 lines | Just table inserts |
| Pass 2 checker | ~500 lines | This is where most iteration happens |
| Annotation table + Shape type | ~150 lines | Simple data definitions |
| Emitter | ~400 lines | Dumb case statement |
| Cache (hash + msgpack) | ~150 lines | Mostly glue |
| **Total** | **~2200 lines** | Before tests |

This is a manageable project. The checker is where you'll spend most debugging
time, but because errors are collected (not thrown) and every function is checked
independently, you can test individual functions in isolation from day one.

### The Right Build Order

Don't try to build everything at once. Each step gives you something runnable:

```
Step 1 — Lexer only
  Input:  "fn add({a: int}) -> int:\n  a + 1"
  Output: print the token list
  Done when: all token kinds lex correctly, indent/dedent emitted properly

Step 2 — Parser (no IR yet, just print what you parse)
  Input:  token stream
  Output: print "parsed fn: add, params: [{a: int}], ret: int"
  Done when: every valid program parses without error

Step 3 — IR building (parser writes to seq[IRNode])
  Input:  token stream
  Output: print the IR node list with indices
  Done when: IR structure matches what you'd draw by hand

Step 4 — Pass 1 (collect signatures)
  Input:  IR
  Output: print the signature table
  Done when: all fn names and return types appear correctly

Step 5 — Pass 2 (check one simple fn body)
  Start with: irConst and irCall only. No if, no match.
  Done when: a type mismatch produces a clear error message

Step 6 — Emitter (dumb, emit Nim source)
  Input:  IR + annotations
  Output: a .nim file that compiles
  Done when: "fn double({n: int}) -> int: n * 2" round-trips correctly

Step 7 — Cache
  Add last. Everything should work without it.
  Done when: second run of unchanged file is noticeably faster
```

Get to step 6 before adding any advanced features (actors, decision tables,
sealed types). A working end-to-end pipeline for simple functions is worth more
than a sophisticated checker that can't emit anything.
