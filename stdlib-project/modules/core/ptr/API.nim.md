# core.ptr — Nim API

## Purpose
Raw addresses, for the few places that genuinely need them: allocators, FFI boundaries, and hardware registers. Everyday code should be using `View[T]` from `core.slice` instead, and this module's names are deliberately shaped so you notice when you've left that path.

## Protocols implemented
**None — this is a primitive/domain module.** It does use the `read`/`write` verbs from the table, with the same shape they have everywhere else.

## The API

```nim
type
  RawPtr*[T] = ptr T
    ## An address. May be nil. Every operation on it is spelled out, never implied.
  SurePtr*[T] = distinct ptr T
    ## An address that is statically never nil. `Option[SurePtr[T]]` costs the same
    ## as a bare pointer, because `none` reuses the nil bit pattern.

func nothing*[T](_: typedesc[T]): RawPtr[T]        ## the null pointer, named
func isNothing*[T](p: RawPtr[T]): bool
func sure*[T](p: RawPtr[T]): Option[SurePtr[T]]    ## absent if it was nil
func loose*[T](p: SurePtr[T]): RawPtr[T]

func atOffset*[T](p: RawPtr[T], elements: int): RawPtr[T] {.raises: [].}
  ## Pointer arithmetic in units of T, not bytes — the off-by-sizeof bug can't happen.
func recast*[T, U](p: RawPtr[T], _: typedesc[U]): RawPtr[U]

proc read*[T](p: SurePtr[T]): T
  ## A plain load. The compiler may cache, reorder or elide it.
proc write*[T](p: SurePtr[T], value: T)
  ## A plain store, bit-for-bit, with no destructor run on whatever was there.

proc readDevice*[T](p: SurePtr[T]): T
  ## A load the compiler must actually perform, exactly once, in order.
proc writeDevice*[T](p: SurePtr[T], value: T)
  ## A store the compiler must actually perform, even if it looks redundant —
  ## which is what makes toggling a GPIO pin work.

proc copyTo*[T](source, dest: SurePtr[T], elements: Count)
  ## Regions may overlap.
proc copyToDisjoint*[T](source, dest: SurePtr[T], elements: Count)
  ## Faster; the caller promises the regions don't overlap.

func viewOf*[T](p: SurePtr[T], elements: Count): View[T]
  ## The exit door back to safety: attach a length and stop using raw pointers.
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Ptr<T>` | `RawPtr[T]` | "Raw" in the name every single time it appears, so an unusual thing looks unusual. |
| `NonNull<T>` | `SurePtr[T]` | A double negative became a positive word. `sure()`/`loose()` convert between the two. |
| `null()` / `is_null()` | `nothing()` / `isNothing()` | Ties the null pointer to the library's one word for absence, instead of teaching a second one. |
| `offset` / `add` | `atOffset` | Two names for the same operation (signed and unsigned) collapsed into one; the `at` prefix reads as a location, not a mutation. |
| `read_volatile` / `write_volatile` | `readDevice` / `writeDevice` | The best rename here. "Volatile" says nothing about *why*; "device" says exactly when you need it — this address is hardware, not memory. |
| `cast<U>()` | `recast(p, U)` | `cast` is a Nim keyword, and `recast` signals reinterpretation rather than conversion. |
| `copy_nonoverlapping` | `copyToDisjoint` | Shorter, and states the promise rather than negating a condition. |
| `from_raw_parts` (in core.slice) | `viewOf(p, n)` | Lives here, next to the pointers, and is named for what you get out rather than what goes in. |

## In use

```nim
# embedded-sensor-node: toggling the status LED through an MMIO register
const gpioSet = cast[SurePtr[uint32]](0x4002_1018'u)
gpioSet.writeDevice(1'u32 shl ledPin)      # never optimised away

let status = i2cStatus.readDevice()        # re-read every time, as the datasheet requires
if status.hasBit(busErrorBit): recover()

# mp3-player: a buffer from the C decoder, made safe at the boundary
proc frames(raw: RawPtr[int16], n: Count): Option[View[int16]] =
  raw.sure().map(proc (p: SurePtr[int16]): View[int16] = p.viewOf(n))
```

## Vocabulary exceptions
`atOffset`, `recast`, `copyTo`, `copyToDisjoint`, `sure`, `loose` and `viewOf` are domain verbs — pointer arithmetic has no structural analogue and forcing it into `get`/`set` would badly misrepresent the cost and the danger. `read`/`write` are used in their exact table sense (pull data out, push data in). `copyTo` deviates from the table's `copy(target)` (which returns an independent duplicate) because a pointer copy writes into a destination the caller supplies; the `To` suffix marks the difference.
