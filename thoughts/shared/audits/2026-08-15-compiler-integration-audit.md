# Compiler Integration Audit — 2026-08-15

Read against the tree at `claude/spec-code-audit-34xh4q`. Every claim below is
cited to `file:line` or to a probe that was actually run; nothing is taken from
the markdown docs, several of which have drifted (see F9).

Baseline: `tests/run --check` is **green** — 175 assertions skipped as needing a
backend build, zero failures. `known_bugs.nim` holds 19 `bugFixed` and 1
`bugOpen`. So none of what follows is a broken tree. It is all *gaps the suite
does not currently assert*, which is the more dangerous category: the compiler
reports success on programs it should reject.

The findings are ranked by consequence, not by count.

---

## F1 — Undeclared names are not checked, so `tuck ch` passes typos

**Severity: critical. This is the root finding; F2 and F3 are its symptoms.**

`tuck ch` returns OK on a call to a function that does not exist. The rejection
happens later, in **Nim**, against generated code, with a Nim spell-suggestion
naming Nim internals.

```tuck
fn helper({n: int}) -> int:
  return n

fn main() -> int:
  return helpr {1}        # note the typo
```

```
$ ./tuck ch typo.tuck
OK (1.1 ms)
```

The real `helper` is one line above. Types are checked strictly — passing
`{"str"}` to `helper` is caught cleanly with a coded diagnostic — but **names
are not checked at all**.

Taken further, `./tuck b` on an undeclared callee produces:

```
ghost.nim(4, 3) Error: undeclared identifier: 'totallyUndefinedFunction'
candidates (edit distance, scope distance); see '--spellSuggest':
 (15, 4): 'onThreadDestruction'
```

The user wrote Tuck and is being shown Nim's opinion about Nim's symbol table.

### The mechanism

Deliberate, and documented at `compiler/typecheck.nim:24`:

> GRADUAL BY DESIGN. An undeclared symbol synthesizes Unknown, and Unknown is
> compatible with everything. So half-written sketch code still compiles while
> the parts you HAVE declared are checked strictly. This is what makes Tuck's
> `pending:` blocks work.

The design conflates two different situations:

- **`pending:`** — *"I told you the signature, the body comes later."* The
  compiler has the name and the type. Gradual typing is exactly right here.
- **an undeclared name** — *"I have never heard of this symbol."* The compiler
  has nothing. This is a typo, and treating it as gradual is what defers the
  error to the backend.

`pending:` does not need undeclared-name permissiveness to work, because a
`pending:` declaration **is** a declaration. The two were merged into one rule
and only one of them needed it.

### It is a known gap

`tests/suites/actor_result.nim:9-10` says so outright:

```
## there should be an undeclared-name error — still open below, because
## undeclared names are unchecked generally (not an actor problem).
```

And the diagnostic already exists: `dcTyUndeclared = "TK-TY03"`
(`compiler/diagnostics.nim:66`, *"name is neither field nor fn"*). It is applied
at only three sites (`typecheck.nim:637`, `:648`, `:2952`) — pool element types
and two others. The machinery is built; it is not wired to callees.

There is also a dead lever: `when defined(strictUnknown): return false` at
`compiler/typecheck.nim:274`. **One** call site, no build config defines it, no
test exercises it. Someone anticipated this and left the switch half-installed.

### The single point of origin

`compiler/typecheck.nim:1867` — `synthCall`, the last line:

```nim
proc synthCall(tc: var TypeChecker, e: Expr): Type =
  ## What `{payload} name` means, in priority order: a restructuring builtin,
  ## then a name (distinct / construction / declared fn), then a callee that
  ## is not a bare name at all. Nothing claims it -> Unknown, gradually.
  let calleeName = tc.calleeNameOf(e)
  result = tc.asRestructuringBuiltin(e, calleeName)
  if result != nil: return
  result = tc.asNamedCallee(e, calleeName)
  if result != nil: return
  if e.callee != nil and e.callee.kind != exkVar:
    return tc.asIndirectCall(e)
  return tc.synthArgsUnknown(e)      # <- F1 lives here
```

The whole finding is that **one** fallthrough. `asNamedCallee` (`:1844`) is the
ordered chain of interpretations; when every one declines and the callee *is* a
bare name (`exkVar`), the name was simply never declared — and that case is
currently indistinguishable from a legitimately gradual one.

This is narrower than first assessed. The fix is a branch here, not a change to
the `Unknown` type across the checker: when the callee is a bare `exkVar` name
that nothing claimed, report `TK-TY03` instead of calling `synthArgsUnknown`.
`pending:` is unaffected — a `pending:` fn is collected into `fnSigs`
(`collectFnSig:2548`), so `asNamedCallee` claims it and never reaches this line.

### Recommendation

Change the `synthCall` fallthrough as above. Gate behind a flag if the corpus
needs to migrate, and per `run-a-new-rule-over-the-corpus-first` run it over
`examples/` and the suites **before** writing new tests; expect hits in the
teaching material.

The same treatment is needed for the two other accepted cases in F2 (undeclared
var read, undeclared param type), which have their own fallthroughs —
`synthVar:1950` and the param path — so "one branch" applies per site, not once
in total.

---

## F2 — The undeclared-name boundary is inconsistent within one signature

**Severity: high. Same root as F1, but this is the part that reads as arbitrary.**

Probed each form directly (`./tuck ch`, one construct per file):

| Construct | Result |
|---|---|
| undeclared **callee** | **ACCEPTED** |
| undeclared **var read** | **ACCEPTED** |
| undeclared **param type** | **ACCEPTED** |
| undeclared assignment target | rejected |
| undeclared type annotation (`var x: NoSuchType`) | rejected |
| undeclared **return** type | rejected |
| undeclared field read | rejected |

The sharpest pair is param vs return type — **in the same signature**:

```tuck
fn takesGhost({n: NoSuchType}) -> int:    # accepted
  return 0
```

```
$ ./tuck ch asym.tuck
OK (2.8 ms)
```

but `fn f() -> NoSuchType:` is rejected. The accepted one emits
`proc tuck_takesGhost*(n: NoSuchType): int` and dies in Nim.

A user cannot learn this rule, because there isn't one — it is wherever a check
happened to get written. Whatever F1's resolution is, these seven cases must
end up with **one** rule between them.

---

## F3 — `echo` exists in the Odin backend only

**Severity: high. Small in size, exemplary of the seam.**

`compiler/codegen_odin.nim:678`:

```nim
if calleeStr == "echo": return "fmt.println(" & args.join(", ") & ")"
```

Nothing else in the compiler knows `echo`. Not the lexer, not the parser, not
the typechecker, not `std/`, not `codegen.nim`. Grep for `"echo"` across
`compiler/` returns exactly that one line.

It works on the Nim backend **by accident**: `echo` is undeclared, F1 lets it
through untouched, and Nim happens to have a proc of that name. Verified:

```tuck
fn main() -> int:
  echo {"hi"}
  return 0
```
emits `echo("hi")` and builds. Odin has no such symbol, so it needed the
explicit arm — and got one, in the backend, rather than in the frontend where a
builtin belongs.

Consequences: `echo`'s arity and argument types are unchecked on both backends;
it carries no `[io]` effect, so it is invisible to the effect system that
`typecheck.nim` otherwise enforces; and its two backends can diverge silently.

**Recommendation:** either declare it in `std/` like any other function, or make
it a real builtin known to the checker with a signature and an `[io]` effect.
Not a string compare in one emitter.

---

## F4 — The builtin set is spelled as string literals in five places

**Severity: high (internal shape).**

`bake` / `alias` / `merge` are re-recognized by string comparison at each stage
that cares:

| Site | Code |
|---|---|
| `typecheck.nim:1833-1839` | `case calleeName / of "alias": / of "merge": / of "bake":` |
| `typecheck.nim:3098` | `if callee in ["bake", "merge", "alias"]: return` |
| `codegen.nim:460-464` | `if calleeStr == "alias" ... "bake" ... "merge"` |
| `codegen.nim:515-516` | `if calleeStr == "bake" ... "alias"` |
| `codegen_odin.nim:634-639`, `:668-669` | the same three, independently |

Four files each hold their own copy of "what the builtins are". Adding a fourth
builtin means finding all five sites; missing one produces a builtin that
typechecks and emits nothing, or emits without being checked — which is exactly
F3's shape.

The project's own memory covers this (`enums-not-magic-ints`: *"named enum for
any coded value; never bare int + comment legend"*). A string is a coded value
too.

**Recommendation:** one `BuiltinKind` enum plus a single table mapping name →
kind, resolved once in the checker and recorded in the semantic layer. Codegen
then switches on the enum and Nim's exhaustiveness check covers the arms — the
same guarantee the AST dispatches already get.

---

## F5 — Both codegen decl dispatches end in `else`, defeating the exhaustiveness guarantee

**Severity: medium-high (latent, not currently firing).**

`compiler/codegen.nim:1848`:
```nim
  else:
    return "# [codegen] ignored decl kind " & $d.kind & "\n"
```

`compiler/codegen_odin.nim:2315`:
```nim
  else:
    return ""
```

Both dispatches currently cover the same 18 kinds; the three absent —
`dkSelect`, `dkSatisfies`, `dkWhen` — are legitimately erased or consumed
upstream (`modules.nim:265`, `typecheck_conformance.nim:139`,
`codegen_common.nim:71`). So **no bug fires today**.

The defect is that the `else` makes "erased upstream" and "nobody implemented
this yet" indistinguishable. A new `DeclKind` added tomorrow compiles clean and
silently emits nothing. This directly contradicts the project's stated rule
(`exhaustive-case-no-else`: *"list every enum arm; `else: discard` hides the kind
you forgot to handle"*).

Worse, the two backends disagree about the failure mode: Nim leaves a greppable
comment in the output, Odin returns `""` and leaves no trace at all. A missing
kind is findable in one backend and invisible in the other.

**Recommendation:** replace both `else` arms with an explicit
`of dkSelect, dkSatisfies, dkWhen:` arm carrying the comment that says *why*
each is absent. Costs one line per new kind, forever, and converts a silent gap
into a compile error.

---

## F6 — Four independent whole-tree walkers must be updated in lockstep

**Severity: medium (internal shape).**

`assignIds(Decl)` (`ast.nim:647`, cc=20) and `clearIds(Decl)` (`ast.nim:795`,
cc=16) are the **same traversal written twice** — identical arms, differing only
in the action taken at each node:

```nim
# assignIds                              # clearIds
of dkFn: assignIds(d.fnBody, next)       of dkFn: clearIds(d.fnBody)
of dkTask: assignIds(d.taskBody, next)   of dkTask: clearIds(d.taskBody)
of dkConst: assignIds(d.constVal, next)  of dkConst: clearIds(d.constVal)
...                                      ...
```

`ast.nim:709` admits it in the `children` iterator's own doc comment:

> the traversal is the boilerplate, and assignIds/clearIds already hand-roll it
> twice because they mutate.

`children(Expr)` exists and solved this at the expression level. There is no
`children(Decl)`, so the declaration level stays duplicated. Add `mangle.nim`
(18 dk-arm lines across `mangleExpr` cc=22, `mangleModuleWith` cc=22,
`mangleType` cc=17) and there are four places to update per new node kind.

Three of the top-20 complexity offenders are in `mangle.nim` for this reason —
its complexity is *traversal* boilerplate, not mangling logic.

**Recommendation:** add `children(Decl)`, express `clearIds` over it, and give
`mangle` a visitor over the same iterator. The exhaustive `case` then lives in
one place, which is precisely the guarantee `children(Expr)`'s comment argues
for.

---

## F7 — The complexity ratchet is 1280 debt against a stated ceiling of 5

**Severity: medium (honest debt, but the stated rule and the tree disagree).**

Measured with the project's own tool (`./tools/cc lexer.nim tuck.nim compiler/*.nim`):

```
1104 routines in 35 files
  complexity > 5: 298
```

Ratchet values (`tests/suites/complexity.nim:43,115-116`):
`CEILING = 64`, `DEBT = 1280`, `HEAVY = 32`.

Worst offenders:

| cc | lines | site |
|---|---|---|
| 29 | 106 | `parser_stringify.nim:8 toString` |
| 25 | 50 | `typecheck.nim:2686 resolveDeclTypeRefs` |
| 22 | 37 | `codegen.nim:534 genReturn` |
| 22 | 56 | `mangle.nim:148 mangleExpr` |
| 22 | 47 | `mangle.nim:271 mangleModuleWith` |
| 20 | 59 | `ast.nim:587 assignIds` |
| 20 | 84 | `codegen_odin.nim:2232 genOdinDecl` |

The ratchet is working as designed — it cannot get worse and it self-reports
slack. But `feedback-complexity` states *"cyclomatic complexity > 5: split
unconditionally"*, and 298 routines exceed it. The rule as written is not the
rule in force.

Note the interaction with F5/F6: several of these are high **because** dispatch
is duplicated. Fixing F6 lowers `mangle.nim`'s three entries without any
deliberate refactor. Do the structural fixes first and re-measure before
attacking the list directly.

**Recommendation:** keep the ratchet, but restate the rule honestly — a big flat
`case` over an enum is dispatch, exempt (that exemption is already recognized in
`tables-are-not-branches`); nesting and chained string tests are what gets split.

---

## F8 — `typecheck.nim` is 3611 lines against a stated 800 maximum

**Severity: medium.**

```
3611 compiler/typecheck.nim
2492 compiler/codegen_odin.nim
1951 compiler/codegen.nim
1176 compiler/parser.nim
```

Nine `typecheck_*.nim` modules already exist and are well-factored
(`_flow`, `_pointers`, `_conformance`, `_decisions`, `_transitions`, `_state`,
`_util`). The split was started and stopped; the residue in `typecheck.nim` is
still four times the stated cap and holds 47 dk-arm lines across several
separate dispatches (`:2639`, `:2690`, `:3018`, `:3050`, `:3183`, `:3261`).

The codegen files are a different case — their length is one flat dispatch,
which F5 says should stay whole. Length there is fine; `typecheck.nim` is not
one dispatch.

**Recommendation:** continue the existing split along the seams already
established. Lower priority than F1–F6 — this is size, not correctness.

---

## F9 — The documentation describes a design that no longer exists

**Severity: medium. It misleads exactly when someone is learning the codebase.**

`COMPILER-TOUR.md` (§"A trick worth knowing") teaches:

> `compiler/ast_serializer.nim` has no `else` branch anywhere — every `case`
> over a node kind handles every kind... Add a node kind to `ast.nim` and the
> serializer stops compiling until someone handles it.

The actual file is 22 lines and has no `case` at all — it delegates to `jsony`:

```nim
proc toJson*(m: Module): JsonNode =
  parseJson(jsony.toJson(m))
```

Its own header explains the replacement, and the replacement is **better** (a
hand-written serializer *had* silently stopped emitting 7 ExprKinds and 9
DeclKinds). But the tour still teaches the superseded rationale as a live
example — and the exhaustiveness argument it makes is one the codegen
dispatches then violate (F5).

The `CLAUDE.md` I generated earlier today inherited this error from the tour.
**It has been corrected** as part of this audit.

This is the documented-vs-real drift the user flagged: trust the code.

---

## Suggested order of work

Each item is independently shippable and testable.

1. **F5** — replace the two `else` arms with explicit ones. ~10 lines, zero
   behaviour change, immediately prevents the next silent gap.
2. **F6** — add `children(Decl)`; re-express `clearIds`. Mechanical, and it
   drops several F7 entries as a side effect.
3. **F4** — one `BuiltinKind` enum replacing five string-literal sites. Makes F3
   a one-line addition instead of a four-file change.
4. **F3** — give `echo` a real declaration with an `[io]` effect.
5. **F1 + F2** — the big one. Split the `Unknown` sentinel, wire `TK-TY03` to
   callees, unify the seven-case boundary. Do it behind a flag; run the new rule
   over `examples/` and the suites before writing tests, and expect the teaching
   material to violate it.
6. **F7 / F8** — re-measure after 1–6, then decide.

Items 1–4 are low-risk and mostly mechanical. Item 5 changes what programs are
legal and needs the corpus migration; it is also the one that turns "the design
is right, the implementation is half-baked" into a compiler that actually
enforces its own design.
