# Python stdlib parity catalogue for Tuck

Uses Python's everyday stdlib surface as the parity reference — not because
Tuck should look like Python, but because Python's naming is famously
readable and its "batteries" list is a good checklist of what an ordinary
program needs. Every signature below is real Tuck syntax: postfix calls,
struct payloads, effect markers. See [[STDLIB-PROPOSAL.md]] for the
cross-batch synthesis this extends, and [[DISCOVERIES.md]] for the bugs
that gate some of these (referenced inline as "gated on Discoveries #N").

Tiering: **TIER 1** = can't write ordinary programs without it. **TIER 2**
= any developer expects it. **TIER 3** = nice to have.

---

## Where Python's design should NOT be copied — read this first

1. **No exceptions as control flow.** Python's `int(s)` raises `ValueError`;
   `dict[k]` raises `KeyError`; `list.pop()` raises `IndexError`. Tuck has no
   `try`/`except` and no unwind — every fallible stdlib fn below returns
   `!T` (result) or `?T` (optional) instead. This is a bigger surface
   change than it looks: Python code leans on exceptions for *early exit*
   too (`next(iter, default)` swallowing `StopIteration`), and that idiom
   has no Tuck equivalent — callers must narrow explicitly. Currently
   blocked entirely: there is no verified `!T` unwrap idiom
   (Discoveries #9, DISCOVERIES.md "no `expr?`"), so every `!T` signature
   here is aspirational until that lands.
2. **No duck typing / dynamic dispatch.** Python's `len(x)`, `str(x)`,
   `x + y` work on anything with the right dunder method. Tuck is
   monomorphic-by-struct: `toStr` is one generic fn today
   (`fn toStr[T]({value: T}) -> str` in std/str.tuck), not an open protocol.
   Do not propose a Python-style `__eq__`/`__lt__`/`__str__` operator-overload
   story — record equality is already structural and built into the
   language (verified, DISCOVERIES.md "CONFIRMED WORKING"); ordering should
   be an explicit opt-in `derive Ord`, not implicit protocol conformance.
3. **No lazy iterators / generators.** `itertools`, `enumerate`, `zip`,
   `map`/`filter` as Python objects are all lazy, pull-based, and backed by
   `__next__`/coroutine machinery. Tuck has no closures and no generators
   today, so every `list`/`seq` fn below is **eager**: `filter` returns a
   full `Seq[T]`, not a view. This means chained pipelines
   (`xs.filter(...).map(...).take(5)`) materialize an intermediate seq at
   every step — acceptable for a systems language, but do not port
   `itertools.islice`/`itertools.chain`-style infinite-sequence idioms;
   they need laziness to be safe and Tuck can't express that yet.
3b. **No regex (`re`).** Pattern matching against dynamic typing and
   backtracking is a different complexity/dependency class than the rest of
   this list. Out of scope for parity; `str::split`/`str::startsWith` etc.
   cover the common cases without a regex engine.
4. **No `**kwargs`/`*args`, no default parameter values, no keyword-only
   args.** Every Tuck fn takes exactly one struct payload; "optional
   argument" in Tuck means a field with an `?T` type the caller sets to
   the equivalent of `none`, not a Python-style default expression
   evaluated at def time (which also avoids Python's classic mutable-default
   footgun — there's nothing to default to).

---

## std/str — biggest single gap (batch E consensus)

```tuck
fn split({text: str, sep: str}) -> Seq[str]              # str.split(sep)         TIER 1
fn join({items: Seq[str], sep: str}) -> str               # sep.join(items)        TIER 1
fn upper({text: str}) -> str                               # str.upper()            TIER 1
fn lower({text: str}) -> str                               # str.lower()            TIER 1
fn trim({text: str}) -> str                                 # str.strip()            TIER 1
fn reverse({text: str}) -> str                              # text[::-1]             TIER 1
fn parseInt({text: str}) -> !int                            # int(str)               TIER 1  # gated on !T unwrap
fn charAt({text: str, index: int}) -> str                   # str[i]                 TIER 1  # gated on char story; byte semantics, see STDLIB-PROPOSAL §1.5
fn startsWith({text: str, prefix: str}) -> bool             # str.startswith()       TIER 2
fn endsWith({text: str, suffix: str}) -> bool               # str.endswith()         TIER 2
fn contains({text: str, needle: str}) -> bool               # needle in str          TIER 2
fn indexOf({text: str, needle: str}) -> int                 # str.find()  (-1 miss, NOT ValueError like str.index()) TIER 2
fn replace({text: str, old: str, replacement: str}) -> str          # str.replace()          TIER 2
fn substring({text: str, start: int, stop: int}) -> str     # str[start:stop]        TIER 2
fn repeat({text: str, times: int}) -> str                   # str * n                TIER 2
fn countOccurrences({text: str, needle: str}) -> int        # str.count()            TIER 2
fn padLeft({text: str, width: int, fill: str}) -> str       # str.rjust()            TIER 3
fn padRight({text: str, width: int, fill: str}) -> str      # str.ljust()            TIER 3
fn isDigit({text: str}) -> bool                             # str.isdigit()          TIER 3
fn isAlpha({text: str}) -> bool                              # str.isalpha()          TIER 3
fn capitalize({text: str}) -> str                            # str.capitalize()       TIER 3
```
Rejected from Python: `str.format`/f-strings/`%`-formatting as a mini
language — postfix `+` concat plus `std/fmt` number formatting already
covers presentation without embedding an expression sub-language in string
literals. `str.encode`/`bytes` — no bytes type in scope here.

## std/seq — growable storage (gated entirely on Discoveries growable-seq gap)

```tuck
fn push[T]({items: Seq[T], value: T}) -> Seq[T]            # list.append()          TIER 1  # gated: no growable seq yet
fn len[T]({items: Seq[T]}) -> int                            # len(list)   (NOTE: `.len` already works as a method, see SYNTAX.md) TIER 1
fn at[T]({items: Seq[T], index: int}) -> T                   # list[i]                 (exists: std/seq.tuck)
fn setAt[T]({items: Seq[T], index: int, value: T}) -> void   # list[i] = v             (exists: std/seq.tuck)
fn slice[T]({items: Seq[T], start: int, stop: int}) -> Seq[T] # list[start:stop]      TIER 2
```

## std/list — eager higher-order algorithms over std/seq storage

```tuck
fn filter[T]({items: Seq[T], pred: fn}) -> Seq[T]           # filter(pred, list) / list comprehension  TIER 1
fn map[T, U]({items: Seq[T], transform: fn}) -> Seq[U]       # map(fn, list) — NOT param name `fn:`, reserved word TIER 1
fn count[T]({items: Seq[T], pred: fn}) -> int                # sum(1 for x in xs if pred(x))  TIER 1
fn sum({items: Seq[int]}) -> int                              # sum(list)               TIER 1
fn min({items: Seq[int]}) -> int                              # min(list)               TIER 1
fn max({items: Seq[int]}) -> int                              # max(list)               TIER 1
fn contains[T]({items: Seq[T], value: T}) -> bool             # value in list           TIER 1
fn indexOf[T]({items: Seq[T], value: T}) -> int               # list.index()  (-1 miss, not ValueError) TIER 1
fn any[T]({items: Seq[T], pred: fn}) -> bool                  # any(pred(x) for x in xs) TIER 2
fn all[T]({items: Seq[T], pred: fn}) -> bool                  # all(pred(x) for x in xs) TIER 2
fn reduce[T, U]({items: Seq[T], init: U, step: fn}) -> U      # functools.reduce()      TIER 2
fn dedup[T]({items: Seq[T]}) -> Seq[T]                        # dict.fromkeys(list) idiom, order-preserving TIER 2
fn sortBy[T]({items: Seq[T], key: fn}) -> Seq[T]              # sorted(list, key=...)   TIER 2  # gated on ordering constraint (Discoveries prereq 6)
fn reverse[T]({items: Seq[T]}) -> Seq[T]                       # list(reversed(list))    TIER 2
fn take[T]({items: Seq[T], n: int}) -> Seq[T]                  # list[:n]                TIER 2
fn skip[T]({items: Seq[T], n: int}) -> Seq[T]                  # list[n:]                TIER 2
fn zip[T, U]({left: Seq[T], right: Seq[U]}) -> Seq[{a: T, b: U}] # zip(a, b)  (eager — NOT a lazy zip object)  TIER 2
fn enumerate[T]({items: Seq[T]}) -> Seq[{index: int, value: T}] # enumerate(list)  (NOTE: `for idx, item in items:` already covers the common case, SYNTAX.md) TIER 2
fn flatten[T]({items: Seq[Seq[T]]}) -> Seq[T]                  # itertools.chain(*lists) TIER 3
fn chunk[T]({items: Seq[T], size: int}) -> Seq[Seq[T]]         # itertools.batched()     TIER 3
```
Rejected from Python: `itertools.islice`/`itertools.count`/`itertools.cycle`
(need laziness/infinite sequences — no generator backing in Tuck yet);
list comprehension syntax itself — Tuck's postfix-chain-of-fn-calls already
covers the same ground without a second expression grammar.

## std/num — scalar math

```tuck
fn abs({value: int}) -> int                                   # abs()                   TIER 1
fn min({a: int, b: int}) -> int                                # min(a, b)                TIER 1
fn max({a: int, b: int}) -> int                                # max(a, b)                TIER 1
fn pow({base: int, exp: int}) -> int                           # a ** b                   TIER 2
fn sqrt({value: int}) -> int                                    # math.sqrt() (int result — see note) TIER 2
fn gcd({a: int, b: int}) -> int                                 # math.gcd()               TIER 2
fn clamp({value: int, low: int, high: int}) -> int              # no direct Python builtin (min(hi,max(lo,v)) idiom) TIER 2
fn sign({n: int}) -> int                                         # no direct Python builtin ((n>0)-(n<0) idiom) TIER 2
fn average({items: Seq[int]}) -> float                           # statistics.mean()       TIER 2  # gated on int-division ruling
fn floorDiv({a: int, b: int}) -> int                              # a // b                  TIER 1  # gated on int-division ruling (STANDING PROPOSAL: type-directed `/`)
fn isEven({n: int}) -> bool                                       # n % 2 == 0              TIER 3
fn isOdd({n: int}) -> bool                                        # n % 2 != 0              TIER 3
```
Note: no separate `std/math` — one scalar-math home per STDLIB-PROPOSAL.
`math.sin`/`cos`/`log`/`pi` etc. are out of scope for this parity pass
(no float trig demand seen in the 155-example corpus); add on demand.

## std/map — dictionary (Discoveries #18: `Map[K,V]` is not a real type yet)

```tuck
fn get[K, V]({m: Map[K, V], key: K}) -> ?V                      # dict.get(key)           TIER 1  # gated: Map type doesn't exist
fn set[K, V]({m: Map[K, V], key: K, value: V}) -> Map[K, V]     # dict[key] = value        TIER 1  # gated: Map type doesn't exist
fn has[K, V]({m: Map[K, V], key: K}) -> bool                      # key in dict              TIER 1  # gated: Map type doesn't exist
fn keys[K, V]({m: Map[K, V]}) -> Seq[K]                            # dict.keys()              TIER 2  # gated: Map type doesn't exist
fn values[K, V]({m: Map[K, V]}) -> Seq[V]                          # dict.values()            TIER 2  # gated: Map type doesn't exist
fn remove[K, V]({m: Map[K, V], key: K}) -> Map[K, V]                # del dict[key]            TIER 2  # gated: Map type doesn't exist
```
Rejected from Python: `dict[key]` raising `KeyError` on miss — Tuck's `get`
returns `?V` instead, consistent with rejecting exceptions-as-control-flow
above. No `defaultdict`/`Counter`/`OrderedDict` subclass zoo — one `Map`
type; `Counter`-like counting is `list::count` composed with `map::set`.

## std/set — set type (same gate as std/map)

```tuck
fn add[T]({s: Set[T], value: T}) -> Set[T]                       # set.add()                TIER 2  # gated: Set type doesn't exist
fn has[T]({s: Set[T], value: T}) -> bool                           # value in set             TIER 2  # gated: Set type doesn't exist
fn union[T]({a: Set[T], b: Set[T]}) -> Set[T]                       # a | b                    TIER 3  # gated: Set type doesn't exist
fn intersect[T]({a: Set[T], b: Set[T]}) -> Set[T]                    # a & b                    TIER 3  # gated: Set type doesn't exist
```

## std/fmt — presentation, split from std/str (STDLIB-PROPOSAL charter)

```tuck
fn toFixed({value: float, places: int}) -> str                    # f"{v:.2f}"               TIER 2
fn padNumber({value: int, width: int}) -> str                       # f"{v:04d}"               TIER 3
```
Rejected from Python: sprintf-style `%`/`.format()`/f-string mini-language
as a general mechanism — a handful of named `fmt` fns cover the actual
formatting needs seen in the corpus without adding a parser for format
strings.

## std/opt — `?T` helpers

```tuck
fn unwrapOr[T]({self: ?T, fallback: T}) -> T                        # x if x is not None else fallback   TIER 2  # NOTE: Discoveries #13 — unwrapOr currently emits a curried call, verify before relying on it
fn isSome[T]({self: ?T}) -> bool                                    # x is not None            TIER 2
fn isNone[T]({self: ?T}) -> bool                                    # x is None                TIER 2
```

## std/random — `[io]` throughout (deliberately, per STDLIB-PROPOSAL: nondeterminism is an effect)

```tuck
fn randomInt({low: int, high: int}) -> int [io]                     # random.randint()         TIER 3
fn randomBool() -> bool [io]                                         # random.random() < 0.5    TIER 3
fn choice[T]({items: Seq[T]}) -> T [io]                               # random.choice()          TIER 3
fn shuffle[T]({items: Seq[T]}) -> Seq[T] [io]                          # random.shuffle() (returns new seq — Tuck avoids Python's in-place-mutation-of-arg style here since payloads are values) TIER 3
```

## std/time — already exists (std/time.tuck); parity additions

```tuck
fn nowMs() -> {ms: u64} [io]                                          # time.time()              (exists)
fn sleepMs({ms: u32}) -> void [io, may_block]                          # time.sleep()             (exists)
fn formatDate({ms: u64}) -> str [io]                                     # datetime.strftime()      TIER 3  # own module, not a datetime CLASS — no Python-style date-arithmetic operators
```
Rejected from Python: `datetime`/`timedelta` as rich objects with operator
overloading (`d1 - d2`, `d + timedelta(...)`) — Tuck has no operator
overloading story; date math would be explicit fns (`addDays`, `diffMs`)
if/when demanded, not `+`/`-` on a date struct.

## std/io, std/fs, std/sys — already exist; no parity gaps found

`print`/`printLine`/`readLine` (std/io), `readFile`/`writeFile`/
`fileExists` (std/fs), `argCount`/`argAt`/`getEnv`/`exit` (std/sys) cover
Python's `print`/`input`, `open()`/`os.path.exists`, and `sys.argv`/
`os.environ`/`sys.exit` respectively. Python's `os.path` join/dirname/
basename helpers are a plausible TIER 3 add to std/fs if path-manipulation
demand shows up; not in this pass.

## Explicitly out of scope (no parity fn proposed)

- `json` — needs a dynamic/`Any` value type Tuck doesn't have; would need
  its own sum-type design (`JsonValue = Null | Bool | Number | Str | ...`)
  as a prerequisite, not a leaf stdlib addition.
- `re` — see rejection #3b above.
- `collections.Counter`/`OrderedDict`/`defaultdict`/`deque` — `Counter`
  composes from `map`+`list::count`; `deque` needs a distinct storage type
  with O(1) front-push not asked for by any example in the corpus.
- `functools.lru_cache`/decorators generally — no decorator syntax in Tuck.
- `contextlib`/`with` — no RAII/context-manager story in the language today.

---

## Tier 1 summary (cannot write ordinary programs without these)

`str`: split, join, upper, lower, trim, reverse, parseInt, charAt.
`seq`: push, len.
`list`: filter, map, count, sum, min, max, contains, indexOf.
`num`: abs, min, max, floorDiv.
`map`: get, set, has.

Every one of these is gated on at least one open language prereq from
STDLIB-PROPOSAL §1 (mangling, growable seq, int division, `!T` unwrap,
char story, or `Map[K,V]` as a real type) — none can ship today as-is.
