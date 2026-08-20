# alloc.set — Nim API

**Purpose**
Keep a collection of things where each thing appears once. `HashSet[T]` for "is this in there?", `SortedSet[T]` for when you also need them in order.

**Protocols implemented**
`Collection[T]`, per PROTOCOLS' assignment table. `has` also makes it `Gettable[T, T]` in practice, though membership is the point rather than retrieval.

## The API

```nim
type
  HashSet*[T] = object    ## literally a Table[T, void] inside — same hashing, same allocator story
  SortedSet*[T] = object  ## tree-backed; iterates in order, which is the only reason to pick it

proc newHashSet*[T](memory = defaultMemory()): HashSet[T]
proc newHashSet*[T](capacity: int; memory = defaultMemory()): HashSet[T]
  ## Say the size up front for a bulk load. 100k words into a default-sized set is a dozen rehashes.

proc add*[T](s: var HashSet[T]; item: T): bool {.discardable.}
  ## true if it wasn't already there. Raises OutOfMemory if it must grow and can't.
proc tryAdd*[T](s: var HashSet[T]; item: T): bool     ## false on allocation failure, never raises
proc has*[T](s: HashSet[T]; item: T): bool            ## the whole reason this type exists
proc remove*[T](s: var HashSet[T]; item: T): Option[T]
proc count*[T](s: HashSet[T]): int
proc clear*[T](s: var HashSet[T])
proc keepIf*[T](s: var HashSet[T]; pred: proc (item: T): bool)
iterator list*[T](s: HashSet[T]): T                   ## the sole Collection primitive; order unspecified

iterator union*[T](a, b: HashSet[T]): T               ## lazy — no set is allocated unless you ask
iterator both*[T](a, b: HashSet[T]): T                ## in a and in b
iterator onlyIn*[T](a, b: HashSet[T]): T              ## in a, not in b
proc collect*[T](items: iterator: T; memory = defaultMemory()): HashSet[T]
  ## The explicit "yes, allocate a real set from that" step.

proc newSortedSet*[T](memory = defaultMemory()): SortedSet[T]
proc add*[T](s: var SortedSet[T]; item: T): bool {.discardable.}
proc has*[T](s: SortedSet[T]; item: T): bool
proc remove*[T](s: var SortedSet[T]; item: T): Option[T]
proc first*[T](s: SortedSet[T]): Option[T]
proc last*[T](s: SortedSet[T]): Option[T]
iterator list*[T](s: SortedSet[T]): T                 ## always in sorted order
iterator between*[T](s: SortedSet[T]; low, high: T): T
```

`isEmpty`, `contains`, `toSeq`, `each` come from `Collection` and are not restated.

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `HashSet<T>` | `HashSet[T]` | kept: PROTOCOLS' table says so, and Nim's own stdlib uses it. `Set` alone is impossible — Nim's built-in `set` is a bitset over ordinals |
| `BTreeSet<T>` / `TreeSet<T>` | `SortedSet[T]` | names what you get, not the tree it's implemented with. "Do I want things sorted?" is the actual question |
| `insert` | `add` | the structural verb, and it already returns "was this new?" |
| `contains` | `has` | one word, matching every other membership test in the library |
| `intersection` | `both` | three syllables of set theory become one plain word. `for w in both(doc, dictionary)` |
| `difference` | `onlyIn` | says the direction, which `difference(a, b)` never does |
| `range(r)` | `between(low, high)` | guessable without knowing what a `RangeBounds` is |
| `with_capacity_in(n, a)` | `newHashSet(capacity, memory =)` | one constructor, named arguments |
| `.collect_into(HashSet::new_in(&a))` | `.collect(memory =)` | the allocation is still explicit, just not a mouthful |

## In use — spellchecker

```nim
var dictionary = newHashSet[Text](capacity = wordCount)   # counted from the file first: one allocation
for line in dictFile.lines(): dictionary.add(line.trim().toText())

for token in document.words():                            # std.i18n segmentation
  if not dictionary.has(token):
    report(token, suggestions = dictionary.near(token, distance = 2))
```

And todo-cli's tag filter, allocating nothing to answer the query:

```nim
let wanted = ["urgent", "home"].toHashSet()
for task in tasks:
  if count(both(task.tags, wanted)) == wanted.count:       # lazy: no third set is built
    show(task)
```

## Vocabulary exceptions

- **`both` and `onlyIn` are domain verbs for set algebra.** `union` keeps its name because everybody already knows it; `intersection` and `difference` do not clear the "a weekend coder guesses this" bar, and `both`/`onlyIn` do. They obey the argument-order rule and return lazy `iterator`s, so `count(both(a, b))` costs nothing but a scan.
- **Set algebra returns iterators, not sets.** No surprise allocation hides inside what looks like a query — `collect` is where you say you want memory spent.
- **`add` returns "newly added" while `tryAdd` returns "no allocation failure".** Two different booleans on near-identical names, which is the one genuinely sharp edge in this file. Documented rather than smoothed over: if you need both answers, call `has` first.
- **`SortedSet` has no validating app.** Carried forward from the Rust design's own open question, unresolved and honestly flagged: it may belong at `std`.
