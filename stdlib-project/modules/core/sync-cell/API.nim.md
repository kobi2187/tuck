# core.sync-cell — Nim API

## Purpose
Mutable state you can reach through a shared reference, on one thread, without paying for a lock. `Slot[T]` for small values you copy in and out; `Guarded[T]` for bigger ones, where the borrow rules are checked as you go.

## Protocols implemented
`Gettable[void, T]` and `Settable[void, T]` for `Slot[T]` — `get`/`set` with no locator, since a cell holds exactly one thing. `Guarded[T]` implements neither: its whole point is that access is scoped, so it exposes `use`/`edit` blocks instead.

## The API

```nim
type
  Slot*[T] = object
    ## One value you can swap in and out through a shared reference. No checks,
    ## no overhead — a plain memory read or write. `T` must be copyable.
    value: T

  Guarded*[T] = object
    ## One value, with a live count of who's currently looking at it. Costs one
    ## counter check per access, and catches "read it while I was editing it"
    ## at the moment it happens instead of leaving you with silent corruption.
    value: T
    readers: int
    editing: bool

func slot*[T](initial: T): Slot[T]
func get*[T](s: Slot[T]): T                  ## copies out
proc set*[T](s: var Slot[T], value: T)       ## copies in
proc swapIn*[T](s: var Slot[T], value: T): T ## in, and the old one back — as in core.mem

func guarded*[T](initial: T): Guarded[T]

template use*[T](g: Guarded[T], name, body: untyped)
  ## Read-only access for the length of the block. Any number at a time.
  ## `stats.use(s): echo s.wins`
template edit*[T](g: Guarded[T], name, body: untyped)
  ## Exclusive access for the length of the block. Raises `Failure` if anyone
  ## else is inside `use` or `edit` right now.
  ## `log.edit(l): l.append(entry)`

template tryUse*[T](g: Guarded[T], name, body: untyped): bool
template tryEdit*[T](g: Guarded[T], name, body: untyped): bool
  ## Same, but return false and skip the block instead of raising. For code that
  ## would rather back off than fail.

func isBusy*[T](g: Guarded[T]): bool
func readerCount*[T](g: Guarded[T]): Count
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Cell<T>` | `Slot[T]` | "Cell" means a spreadsheet square, a prison, or a phone to most people. A slot is a place one thing goes. |
| `RefCell<T>` | `Guarded[T]` | Names the behaviour (something is watching) instead of the implementation (it holds a reference count). |
| `borrow()` / `borrow_mut()` | `use` / `edit` blocks | The best change in this module. Rust returns a guard object whose *lifetime* is the rule; Nim templates make the block itself the scope, so there's no guard variable to accidentally keep alive, and the two words say why you want access rather than how the borrow checker classifies it. |
| `Ref<T>` / `RefMut<T>` | *(gone)* | With scoped blocks there is no guard type for a user to name, store or leak. |
| `try_borrow` / `try_borrow_mut` | `tryUse` / `tryEdit` | Library-standard `try` prefix, returning a plain `bool` for "did the block run". |
| `replace(value)` | `swapIn(value)` | Same word `core.mem` uses for the same operation. |
| *(unresolved: panic vs Result)* | both, by name | The Rust file left this open. Resolved by the library-wide rule: `edit` raises because a double-edit is a real bug; `tryEdit` exists for callers who want to branch. |

## In use

```nim
# cli-hangman: one game state, reached from both the render and input closures
var game = guarded(newGame(word))

game.use(g): screen.draw(g.masked, g.misses)
game.edit(g):
  if g.secret.has(guess): g.found.setBit(guess.index)
  else: g.misses += 1

# todo-cli: append to the undo log from inside a filter-then-mutate pass
for task in tasks.list().keep(matches):
  undo.edit(log): log.record(task.id, task.done)
  task.done = true
```

## Vocabulary exceptions
`use` and `edit` are domain verbs replacing what could have been `read`/`write`. They earn it: `read`/`write` in this library mean streaming data in and out of a handle (`core.fmt`, `core.ptr`, `sys.io`), and reusing them for scoped borrow acquisition would collide with that meaning in the one place a collision actually confuses — code that does both. `swapIn` is borrowed from `core.mem` rather than invented, per the no-synonyms rule.
