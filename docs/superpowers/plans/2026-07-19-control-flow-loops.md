# Control Flow Loops Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the control-flow spec (docs/superpowers/specs/2026-07-18-control-flow-loops-design.md): `loop:`, `for cond:`, ranges `0 .. 10`/`0 ..< 10`, `for idx, item in items:`, `break`/`continue`, `fn inline`.

**Architecture:** New AST nodes `exkWhile` (cond nil = infinite), `exkBreak`, `exkContinue`; ranges as two new `BinOp` values; indexed for reuses existing `pkTuple`; `fn inline` is a `bool` on `dkFn`. Both backends (Nim + Beef) mirror every emission change.

**Tech Stack:** Nim compiler sources at repo root (`lexer.nim`) and `compiler/` (parser, ast, typecheck, semantics, lowering, ast_serializer, codegen, codegen_beef).

## Global Constraints

- **codegen.nim has TWO genExpr overloads** (`genExpr(e, m)` ~line 420 area and `genExpr(e)` ~line 703 area) — every emission arm lands in BOTH.
- Beef backend mirrors every codegen change (parity commitment; named ceilings allowed with a comment).
- TDD: failing test first, in `tests/typecheck_tests.nim` (parser+checker) and `tests/cli_smoke.sh` (runtime).
- Full matrix before final commit: `typecheck_tests`, `compile_all_examples`, `end_to_end`, `cli_smoke.sh` (`BEEFBUILD_BIN=~/apps/Beef/IDE/dist/BeefBuild`), `beef_backend`.
- Rebuild repo-root binary before CLI probes: `nim c -o:tuck tuck.nim`.
- Nim `quit()` clamps exit codes — use ≤127 in runtime assertions.
- Commit per task (standing OK, no Claude attribution — /commit skill rules).

---

### Task 1: Lexer — new keywords and range tokens

**Files:**
- Modify: `lexer.nim` (TokenKind enum ~line 38, keyword table ~line 67, two-char ops ~line 256)

**Interfaces:**
- Produces tokens: `tkLoop`, `tkBreak`, `tkContinue` (keywords `loop`/`break`/`continue`), `tkRange` (spaced ` .. `), `tkRangeLt` (`..<`). Existing `tkDotDot` stays the tight chain-mutator.

- [ ] **Step 1: Add token kinds and keywords**

In the `TokenKind` enum next to `tkFor, tkIn, tkMatch`:

```nim
    tkFor, tkIn, tkMatch, tkReturn, tkType,
    tkLoop, tkBreak, tkContinue,
```

Near `tkDotDot` in the punctuation kinds:

```nim
    tkRange,      # spaced ` .. ` — inclusive range
    tkRangeLt,    # ..< — exclusive range
```

In the keyword table (~line 68):

```nim
  "loop": tkLoop, "break": tkBreak, "continue": tkContinue,
```

- [ ] **Step 2: Space-sensitive `..` lexing**

The design rule: mutator is tight `..field`; range is spaced `0 .. 10` or `0 ..< 10`. `..<` needs no space check (`<` can never start a field name). Replace the single `tryTwoChar("..", tkDotDot)` line (~line 256) with:

```nim
    if L.peek() == '.' and L.peek(1) == '.':
      if L.peek(2) == '<':
        let sl = L.line; let sc = L.column
        L.advance(); L.advance(); L.advance()
        L.pendingTokens.add(Token(kind: tkRangeLt, value: "..<", line: sl, column: sc))
        return
      # spaced ` .. ` = range; tight `..ident` = chain mutator
      let spacedBefore = L.position > 0 and L.source[L.position - 1] == ' '
      let spacedAfter = L.peek(2) == ' '
      let kind = if spacedBefore and spacedAfter: tkRange else: tkDotDot
      let sl = L.line; let sc = L.column
      L.advance(); L.advance()
      L.pendingTokens.add(Token(kind: kind, value: "..", line: sl, column: sc))
      return
```

(Adjust `L.source[L.position - 1]` to the lexer's actual buffer/peek API — if there is no backward peek, track `lastCharWasSpace` when `skipSpaces` runs; look at how `skipSpaces` and `advance` maintain state and pick the smallest mechanism.)

- [ ] **Step 3: Compile check**

Run: `nim c -o:/tmp/claude-1000/-home-kl-prog-tuck-lexer/fa69d027-a98c-4113-862f-8998586be185/scratchpad/tuck_t1 tuck.nim`
Expected: compiles. (Parser doesn't consume the new tokens yet; existing suites must still pass: `nim r tests/typecheck_tests.nim`.)

- [ ] **Step 4: Commit**

```bash
git add lexer.nim
git commit -m "lexer: loop/break/continue keywords, spaced-range tokens (tkRange, tkRangeLt)"
```

---

### Task 2: AST + mechanical traversal arms

**Files:**
- Modify: `compiler/ast.nim` (ExprKind ~line 152, Expr case ~line 205, BinOp ~line 116, dkFn ~line 270)
- Modify: `compiler/ast_serializer.nim` (~line 135), `compiler/lowering.nim` (~line 117), `compiler/semantics.nim` (~line 69)

**Interfaces:**
- Produces: `exkWhile` (`whileCond*: Expr` — nil = infinite; `whileBody*: Expr`), `exkBreak`, `exkContinue` (no fields), `boRangeIncl`/`boRangeExcl` BinOps, `isInline*: bool` on dkFn.

- [ ] **Step 1: AST additions**

`ExprKind`: add `exkWhile, exkBreak, exkContinue` after `exkFor`.
`Expr` case body:

```nim
    of exkWhile:
      whileCond*: Expr        # nil = infinite loop (`loop:`)
      whileBody*: Expr
    of exkBreak, exkContinue:
      discard
```

`BinOp`: `boAdd, ... boXor` → append `boRangeIncl, boRangeExcl`.
`dkFn`: add `isInline*: bool` after `isExtern`/`externHeader` group.

- [ ] **Step 2: Traversal arms (all three files, same shape)**

`ast_serializer.nim` next to the `exkFor` arm:

```nim
  of exkWhile:
    res["whileCond"] = toJson(e.whileCond)
    res["whileBody"] = toJson(e.whileBody)
  of exkBreak, exkContinue:
    discard
```

`lowering.nim`:

```nim
  of exkWhile:
    if e.whileCond != nil: lowerExpr(e.whileCond, m)
    lowerExpr(e.whileBody, m)
  of exkBreak, exkContinue:
    discard
```

`semantics.nim`:

```nim
  of exkWhile:
    if e.whileCond != nil:
      res = unionEffects(res, c.synthesizeExpr(e.whileCond))
    res = unionEffects(res, c.synthesizeExpr(e.whileBody))
  of exkBreak, exkContinue:
    discard
```

If any of these files use an exhaustive `case` without `else`, the compiler will point at every other file still missing arms (typecheck/codegen get theirs in Tasks 4-6; add temporary `discard` arms there ONLY if compilation of this task requires it, and note it).

- [ ] **Step 3: Compile check + commit**

Run: `nim r tests/typecheck_tests.nim` — expect existing tests green (temporary arms may be needed per Step 2 note).

```bash
git add compiler/ast.nim compiler/ast_serializer.nim compiler/lowering.nim compiler/semantics.nim
git commit -m "ast: exkWhile/exkBreak/exkContinue, range binops, dkFn.isInline + traversal arms"
```

---

### Task 3: Parser — all new forms (TDD)

**Files:**
- Modify: `compiler/parser.nim` (stmt head ~line 786 `tkFor` arm; `parseBinaryExpr` ~line 682; `parseFnDecl` ~line 1230)
- Test: `tests/typecheck_tests.nim`

**Interfaces:**
- Consumes: Task 1 tokens, Task 2 AST nodes.
- Produces: parse of `loop:`, `for cond:`, `for i in a .. b:`, `for i in a ..< b:`, `for idx, item in xs:`, `break`, `continue`, `fn inline name(...)`.

- [ ] **Step 1: Write failing parser tests**

Follow the existing test style in `tests/typecheck_tests.nim` (positive = typechecks clean, negative = expected error substring). Add:

```nim
# loop / while-for / break / continue
checkOk """
fn main() -> int:
  var n = 0
  loop:
    n += 1
    if n == 3: break
  for n > 0:
    n -= 1
    if n == 1: continue
  return n
"""

# ranges + indexed for
checkOk """
fn main() -> int:
  var acc = 0
  for i in 0 .. 3:
    acc += i
  for i in 0 ..< 3:
    acc += i
  let xs = [10, 20, 30]
  for idx, item in xs:
    acc += idx
  return acc
"""

# fn inline parses
checkOk """
fn inline bump({x: int}) -> int:
  return x + 1
fn main() -> int:
  return bump {41}
"""

# break outside loop rejected (checker, Task 4 — write now, passes after Task 4)
checkErr "break outside", """
fn main() -> int:
  break
  return 0
"""
```

(Use the file's actual helper names — `checkOk`/`checkErr` here stand for whatever the suite's pass/fail helpers are called; copy a neighboring test's exact form.)

- [ ] **Step 2: Run to verify failure**

Run: `nim r tests/typecheck_tests.nim`
Expected: new tests FAIL (parse errors on `loop` etc.).

- [ ] **Step 3: Implement parser changes**

**(a) `loop:` / `break` / `continue`** — in the stmt-head chain near the `tkFor` arm (~line 786):

```nim
  elif curr.kind == tkLoop:
    discard p.advance()
    discard p.expect(tkColon)
    let body = p.parseBlock()
    return Expr(span: sp, kind: exkWhile, whileCond: nil, whileBody: body)

  elif curr.kind == tkBreak:
    discard p.advance()
    return Expr(span: sp, kind: exkBreak)

  elif curr.kind == tkContinue:
    discard p.advance()
    return Expr(span: sp, kind: exkContinue)
```

**(b) unified `for`** — replace the existing `tkFor` arm body:

```nim
  elif curr.kind == tkFor:
    discard p.advance()
    # iteration form iff lookahead is `ident in` or `ident , ident in`;
    # anything else after `for` is a while-condition expression
    let isIter = p.current().kind == tkIdent and
      (p.peek(1).kind == tkIn or
       (p.peek(1).kind == tkComma and p.peek(2).kind == tkIdent and
        p.peek(3).kind == tkIn))
    if isIter:
      var iter = p.parsePattern()
      if p.current().kind == tkComma:
        discard p.advance()
        let second = p.parsePattern()
        iter = Pattern(span: iter.span, kind: pkTuple, elems: @[iter, second])
      discard p.expect(tkIn)
      let iterable = p.parseExpr()
      discard p.expect(tkColon)
      let body = p.parseBlock()
      return Expr(span: sp, kind: exkFor, iter: iter, iterable: iterable, body: body)
    else:
      let cond = p.parseExpr()
      discard p.expect(tkColon)
      let body = p.parseBlock()
      return Expr(span: sp, kind: exkWhile, whileCond: cond, whileBody: body)
```

(Check `p.peek` arity — earlier code uses `p.peek(1)`; if peek(3) isn't supported, extend or restructure the lookahead.)

**(c) ranges** — in `parseBinaryExpr`'s `opPrecedences` table add lowest-precedence entries:

```nim
    tkRange: (-2, boRangeIncl), tkRangeLt: (-2, boRangeExcl),
```

and confirm the callers' `minPrecedence` default (`parseBinaryExpr(-2)` is already called at stmt level ~line 795 — range must bind looser than comparisons; verify `for i in 0 .. n - 1:` parses as `0 .. (n-1)`. If `-2` collides with the existing call-site default, use a distinct lower value and adjust).

**(d) `fn inline`** — in `parseFnDecl` right after `discard p.advance()` (eats `fn`, ~line 1230):

```nim
  var isInline = false
  if p.current().kind == tkIdent and p.current().value == "inline":
    isInline = true
    discard p.advance()
```

and set `isInline: isInline` in the `Decl(...)` construction for dkFn (find the construction site in the same proc).

- [ ] **Step 4: Run tests**

Run: `nim r tests/typecheck_tests.nim`
Expected: parse-level tests pass or fail only in the CHECKER (unknown exkWhile handling → Task 4). The `break outside` test still fails until Task 4.

- [ ] **Step 5: Commit**

```bash
git add compiler/parser.nim tests/typecheck_tests.nim
git commit -m "parser: unified for (cond/iter/indexed), loop, break/continue, ranges, fn inline"
```

---

### Task 4: Typecheck

**Files:**
- Modify: `compiler/typecheck.nim` (`synthesize` case ~line 987; `synthBinary` ~line 442; `scanReturns` ~line 195; tail-return notin set ~line 210)

**Interfaces:**
- Consumes: Task 2/3 AST.
- Produces: `TypeChecker.loopDepth: int` field; errors `"break outside of a loop"` / `"continue outside of a loop"`.

- [ ] **Step 1: loopDepth field**

Add `loopDepth: int` to the `TypeChecker` object type.

- [ ] **Step 2: synthesize arms**

Wrap the EXISTING `exkFor` body with depth tracking, and add the new arms:

```nim
  of exkFor:
    discard tc.synthesize(e.iterable)
    tc.pushScope()
    if e.iter != nil and e.iter.kind == pkVar:
      tc.bindName(e.iter.name, unknownType(e.iter.span), false)
    elif e.iter != nil and e.iter.kind == pkTuple:
      # `for idx, item in xs:` — idx is int, item unknown (elem type)
      if e.iter.elems.len >= 1 and e.iter.elems[0].kind == pkVar:
        tc.bindName(e.iter.elems[0].name,
                    Type(span: e.iter.span, kind: tkNamed, name: "int"), false)
      if e.iter.elems.len >= 2 and e.iter.elems[1].kind == pkVar:
        tc.bindName(e.iter.elems[1].name, unknownType(e.iter.span), false)
    let entryVariants = tc.varVariants
    inc tc.loopDepth
    discard tc.synthesize(e.body)
    dec tc.loopDepth
    tc.varVariants = mergeVariants(entryVariants, tc.varVariants)
    tc.popScope()
    Type(span: e.span, kind: tkNamed, name: "unit")
  of exkWhile:
    if e.whileCond != nil:
      let ct = tc.synthesize(e.whileCond)
      if not isUnknown(ct) and typeName(ct) != "bool":
        fail("Type Error: loop condition must be bool, got " & typeName(ct),
             e.whileCond.span)
    let entryVariants = tc.varVariants
    inc tc.loopDepth
    discard tc.synthesize(e.whileBody)
    dec tc.loopDepth
    tc.varVariants = mergeVariants(entryVariants, tc.varVariants)
    Type(span: e.span, kind: tkNamed, name: "unit")
  of exkBreak:
    if tc.loopDepth == 0:
      fail("Control Flow Error: break outside of a loop", e.span)
    Type(span: e.span, kind: tkNamed, name: "unit")
  of exkContinue:
    if tc.loopDepth == 0:
      fail("Control Flow Error: continue outside of a loop", e.span)
    Type(span: e.span, kind: tkNamed, name: "unit")
```

(Match `fail`/`typeName`/`isUnknown` exact helper signatures from neighboring arms. §4.4b merge semantics for exkWhile copied from exkFor deliberately — body checked once, exit = entry ∪ body-exit.)

- [ ] **Step 3: Range typing in synthBinary**

In the `case e.binOp` (~line 451) add before `else`:

```nim
  of boRangeIncl, boRangeExcl:
    for (t, side) in [(lt, e.left), (rt, e.right)]:
      if not isUnknown(t) and typeName(t) notin
         ["int", "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64"]:
        fail("Type Error: range bounds must be integers, got " & typeName(t),
             side.span)
    Type(span: e.span, kind: tkNamed, name: "range")
```

(Check the file's actual integer-type name list — grep for an existing integer-name set and reuse it if one exists.)

- [ ] **Step 4: scanReturns + tail-return sets**

`scanReturns` (~line 195): add `of exkWhile: tc.scanReturns(typeName, e.whileBody, acc, exact)`.
Tail-return notin set (~line 210): extend `{exkReturn, exkIf, exkMatch, exkFor, exkBlock, exkAssign}` with `exkWhile, exkBreak, exkContinue`.

- [ ] **Step 5: Run tests**

Run: `nim r tests/typecheck_tests.nim`
Expected: ALL Task 3 tests pass now, including `break outside`.

- [ ] **Step 6: Commit**

```bash
git add compiler/typecheck.nim
git commit -m "typecheck: while/loop, break/continue depth check, range binop, indexed for"
```

---

### Task 5: Nim codegen (BOTH overloads) 

**Files:**
- Modify: `compiler/codegen.nim` — exkFor arms at ~line 420 (with-m overload) AND ~line 703 (no-m overload); binary op table in both; tail-return notin ~line 868; proc-header emission ~line 979 (and 885/851 sites if fns route through them); statement-kind sets ~lines 465, 753.
- Test: extend an end-to-end or smoke path (Task 7 does runtime; here compile-only probe).

**Interfaces:**
- Consumes: full AST from Tasks 2-4.
- Produces: Nim `while`/`break`/`continue`/`a .. b`/`a ..< b`/`for i, x in`/`{.inline.}` emission.

- [ ] **Step 1: Emission arms — REPEAT IN BOTH OVERLOADS**

Extend the `exkFor` arm for pkTuple and add new arms (shown for the `(e, m)` overload; mirror without `m`):

```nim
  of exkFor:
    let iterStr =
      if e.iter != nil and e.iter.kind == pkVar: e.iter.name
      elif e.iter != nil and e.iter.kind == pkTuple:
        var names: seq[string]
        for el in e.iter.elems:
          names.add(if el.kind == pkVar: el.name else: "_")
        names.join(", ")
      else: "_"
    let oldIndent = ctx.indent
    ctx.indent += 1
    let bodyStr = ctx.genExpr(e.body, m)
    ctx.indent = oldIndent
    ind & "for " & iterStr & " in " & ctx.genExpr(e.iterable, m) & ":\n" & bodyStr
  of exkWhile:
    let condStr = if e.whileCond == nil: "true" else: ctx.genExpr(e.whileCond, m)
    let oldIndent = ctx.indent
    ctx.indent += 1
    let bodyStr = ctx.genExpr(e.whileBody, m)
    ctx.indent = oldIndent
    ind & "while " & condStr & ":\n" & bodyStr
  of exkBreak:
    ind & "break"
  of exkContinue:
    ind & "continue"
```

Note: Nim's `for i, x in seq` uses implicit `pairs` — valid for seqs/arrays; that is exactly our iterable surface today.

Binary op table (both overloads): add

```nim
                of boRangeIncl: ".."
                of boRangeExcl: "..<"
```

and confirm the surrounding emission puts spaces around ops (existing boAdd emission style — copy it).

- [ ] **Step 2: Statement-kind sets**

Lines ~465 and ~753 have sets like `{exkChain, exkFor}` / `{exkIf, exkBlock, exkChain, exkFor}` controlling statement-position emission; ~868 the tail-return notin set. Add `exkWhile` to all three, and `exkBreak, exkContinue` to the ~868 notin set. Read each site's comment first — add only where the semantics match (a while loop is statement-shaped exactly like a for loop).

- [ ] **Step 3: `{.inline.}`**

At the main fn proc-header build (~line 979, `"proc " & fnNameSanitized & "*" & genericStr & ...`): when `d.isInline`, insert the pragma before `=`:

```nim
let inlineStr = if d.isInline: " {.inline.}" else: ""
# header ... & retTypeStr & inlineStr & " ="
```

Check sites ~851/~885 — apply the same if plain `fn` decls route through them (grep which one handles dkFn top-level fns; only touch those).

- [ ] **Step 4: Compile probe**

Write `/tmp/claude-1000/-home-kl-prog-tuck-lexer/fa69d027-a98c-4113-862f-8998586be185/scratchpad/probe_loops.tuck`:

```tuck
fn inline bump({x: int}) -> int:
  return x + 1

fn main() -> int:
  var acc = 0
  loop:
    acc += 1
    if acc == 5: break
  for acc > 3:
    acc -= 1
  for i in 0 ..< 4:
    if i == 2: continue
    acc += i
  let xs = [10, 20, 30]
  for idx, item in xs:
    acc += idx
  return bump {acc}
```

Run: `nim c -o:tuck tuck.nim && ./tuck build <probe> && nim check <emitted .nim>` (use the CLI form the repo's cli_smoke.sh uses). Expected: emitted Nim contains `while true:`, `while acc > 3:`, `0 ..< 4`, `for idx, item in`, `{.inline.}`, and passes `nim check`.

- [ ] **Step 5: Commit**

```bash
git add compiler/codegen.nim
git commit -m "codegen(nim): while/loop/break/continue, ranges, indexed for, {.inline.} — both genExpr overloads"
```

---

### Task 6: Beef codegen mirror

**Files:**
- Modify: `compiler/codegen_beef.nim` (exkFor arm ~line 685; binary table below it; stmt sets ~751, ~886, ~1560; fn header ~line 900/851)

**Interfaces:**
- Consumes: same AST.
- Produces: Beef `while (...)`, `break`, `continue`, `[Inline]`, index-counter lowering for `for idx, item`.

- [ ] **Step 1: Emission arms**

Next to the existing `exkFor` arm:

```nim
  of exkWhile:
    let condStr = if e.whileCond == nil: "true" else: ctx.genBeefExpr(e.whileCond)
    let oldIndent = ctx.indent
    ctx.indent += 1
    let bodyStr = ctx.genBeefExpr(e.whileBody)
    ctx.indent = oldIndent
    return ind & "while (" & condStr & ")\n" & bodyStr
  of exkBreak:
    return ind & "break;"
  of exkContinue:
    return ind & "continue;"
```

(Match how the existing exkFor arm handles the body's braces/indent — copy its exact mechanism, and check whether statements need trailing `;` by looking at how neighboring statement arms emit.)

exkFor pkTuple: Beef's `for (var x in coll)` has no index form; lower with a counter:

```nim
    # ponytail: indexed-for lowers to counter + foreach; revisit if Beef gains an index form
    if e.iter != nil and e.iter.kind == pkTuple and e.iter.elems.len == 2:
      let idxN = genPatternStr(e.iter.elems[0])
      let itemN = genPatternStr(e.iter.elems[1])
      var res = ind & "{\n" & ind & "\tint " & idxN & " = 0;\n"
      res.add(ind & "\tfor (var " & itemN & " in " & iterStr & ")\n")
      # body emitted one level deeper; append idx increment as last stmt inside
      # the foreach body block, then close the outer scope brace
      ...
      return res
```

Work out the exact brace placement from how the existing exkFor arm and parseBlock-emission interact — the increment (`idxN & "++;"`) must be INSIDE the foreach body, after the user statements. If body-block injection is awkward with the current string-based emitter, an acceptable named ceiling: emit the counter block and document `continue` as skipping the increment (WRONG for continue+indexed combined) — better: place the increment at the TOP of the body reading `idxN - 1`... simplest correct form: initialize `int idxN = -1;` and emit `idxN++;` as the FIRST statement of the foreach body, before user code. Then `continue` stays correct. Use that.

Binary table: `of boRangeIncl: "..."` (Beef inclusive spread) — verify against Beef docs/corpus; if Beef lacks `...` for ranges in `for`, emit `boRangeExcl` as `"..<"` (Beef has `..<`) and for inclusive emit `"...(" & hi & " + 1)"`-style exclusive rewrite… Do NOT guess silently: check `~/apps/Beef/BeefLibs` or Beef corpus for `..<`/`...` usage first (`grep -rn "\.\.<" ~/apps/Beef/BeefLibs | head`), then pick.

- [ ] **Step 2: Statement sets + `[Inline]`**

Add `exkWhile` to sets at ~751, ~1560 and `exkWhile, exkBreak, exkContinue` to the notin set ~886. Fn header (~900): when `d.isInline`, prefix attribute line `[Inline]` above `public static ...` (Beef attribute syntax; match indentation of the header line).

- [ ] **Step 3: Verify**

Run: `nim r tests/beef_backend.nim` (expect green) and if BeefBuild present:
`BEEFBUILD_BIN=~/apps/Beef/IDE/dist/BeefBuild bash tests/cli_smoke.sh` (expect existing cases green — new runtime cases come in Task 7).

- [ ] **Step 4: Commit**

```bash
git add compiler/codegen_beef.nim
git commit -m "codegen(beef): while/loop/break/continue, ranges, indexed-for counter lowering, [Inline]"
```

---

### Task 7: Runtime verification + spec + docs sync

**Files:**
- Modify: `tests/cli_smoke.sh` (new runtime case), `tuck-spec.md` (new control-flow section; renumber/place near §2.x statements), `ROADMAP.md` (sync tables), `TOUR-GAPS.md` if any gap entries are now covered
- Create: `examples/` — only if an existing example naturally upgrades (e.g. 20's `for i in chunks:`); do NOT add a new numbered example just for loops unless one of 11/20 needs it

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Runtime smoke case (TDD — add before checking it passes)**

Add to `tests/cli_smoke.sh` following its existing case pattern: compile+run a program whose exit code proves semantics (≤127):

```tuck
fn inline bump({x: int}) -> int:
  return x + 1

fn main() -> int:
  var acc = 0
  loop:
    acc += 1
    if acc == 5: break          # acc = 5
  for acc > 3:
    acc -= 1                    # acc = 3
  for i in 0 ..< 4:
    if i == 2: continue
    acc += i                    # +0 +1 +3 = 7
  for i in 1 .. 3:
    acc += i                    # +1+2+3 = 13
  let xs = [10, 20, 30]
  for idx, item in xs:
    acc += idx                  # +0+1+2 = 16
  return bump {acc}             # 17
```

Expected exit code: 17. Wire both Nim and (if `BEEFBUILD_BIN` set) Beef paths, matching how existing smoke cases do it.

- [ ] **Step 2: Run full matrix**

```bash
nim r tests/typecheck_tests.nim
nim r tests/compile_all_examples.nim
nim r tests/end_to_end.nim
bash tests/cli_smoke.sh
BEEFBUILD_BIN=~/apps/Beef/IDE/dist/BeefBuild bash tests/cli_smoke.sh
nim r tests/beef_backend.nim
```

Expected: all green, including the new exit-17 case on both backends.

- [ ] **Step 3: Spec section**

Add a "Control Flow: Loops" section to `tuck-spec.md` (near the statement/call-model part of Part 2). Content = condensed version of docs/superpowers/specs/2026-07-18-control-flow-loops-design.md: the six forms, spaced-`..` rule, Nim-convention inclusivity, no-labels ruling with fn-extraction + `fn inline` rationale, no C-style for. Also add `inline` to §3.6-adjacent text (a note that `inline` is a codegen keyword slot after `fn`, NOT a purity prefix and NOT an effect marker). Update `ROADMAP.md` rows for loops/break/continue from Missing → Done.

- [ ] **Step 4: Commit + ledger**

```bash
git add tests/cli_smoke.sh tuck-spec.md ROADMAP.md TOUR-GAPS.md progress.md
git commit -m "control flow: runtime smoke (exit 17), spec section, roadmap sync"
```

Update `thoughts/ledgers/CONTINUITY_CLAUDE-examples-all-green.md` (add a Done entry for control-flow loops; note any new capability that unblocks examples 11/20) and add a dated `progress.md` entry.

---

## Self-Review Notes

- Spec coverage: loop:/for-cond/ranges/indexed-for/break/continue/fn-inline → Tasks 3-6; no-labels needs no code; verification section → Task 7. Covered.
- Type consistency: `exkWhile.whileCond/whileBody`, `boRangeIncl/boRangeExcl`, `isInline`, `loopDepth` used with the same names throughout.
- Known judgment calls left to the implementer, each with the decision procedure spelled out: lexer backward-peek mechanism (Task 1), peek(3) arity (Task 3), Beef range-literal spelling (Task 6 — grep BeefLibs first), which proc-header sites take `{.inline.}` (Task 5 — grep which handles dkFn).
