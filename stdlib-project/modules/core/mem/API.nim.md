# core.mem — Nim API

## Purpose
The small set of tools for handling memory on purpose: how big is this, move a value out without leaving a hole, hold a buffer that isn't filled in yet, and wipe secrets so they can't linger.

## Protocols implemented
**None — this is a primitive/domain module.** It operates on memory itself, below the level where "a collection" or "a resource" means anything.

## The API

```nim
func sizeOf*(T: typedesc): Count {.compileTime.}
func alignOf*(T: typedesc): Count {.compileTime.}
func sizeOfValue*[T](x: T): Count      ## for types whose size isn't fixed by the type

proc swap*[T](a, b: var T)
proc swapIn*[T](target: var T, value: T): T
  ## Puts `value` in, hands you back what was there. Nothing is copied, nothing is lost.
proc takeOut*[T](target: var T): T
  ## Hands you the value, leaves `target` at its default. The one-sided `swapIn`.

type
  Unfilled*[T] = object
    ## Memory that is the right size and alignment for a `T` but has no valid `T`
    ## in it yet. The only sanctioned way to say that — there is no
    ## "an ordinary T that happens to hold garbage" anywhere in this library.
    room: array[sizeOf(T), byte]
    filled: bool

func blank*[T](_: typedesc[T]): Unfilled[T]
func zeroed*[T](_: typedesc[T]): Unfilled[T]     ## only where all-zero is a valid T
proc fill*[T](u: var Unfilled[T], value: T)
func get*[T](u: Unfilled[T]): Option[T]
  ## Absent until something filled it. Checked in debug builds, free under
  ## `{.push checks: off.}` in release.
func addressOf*[T](u: var Unfilled[T]): RawPtr[T]
  ## For handing the buffer to a DMA engine or an I2C read that will fill it.

type
  Scrubbed*[T] = object
    ## Wraps a value and overwrites its memory when it goes out of scope, using a
    ## write the optimizer is forbidden to remove.
    value*: T

func scrubbed*[T](value: T): Scrubbed[T]
proc scrub*[T](x: var T)
  ## Wipe it now, without waiting for scope exit.
proc `=destroy`*[T](x: var Scrubbed[T])

proc disown*[T](x: var T)
  ## Suppress this value's destructor: something else (C, DMA, the OS) owns it now.
  ## Named so a leak is always visible in the source.
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `MaybeUninit<T>` | `Unfilled[T]` | The biggest win in this module. "Uninit" is compiler-speak; "unfilled" is what a buffer waiting on a sensor read actually is, and it makes `fill` the obvious next call. |
| `MaybeUninit::uninit()` | `blank(T)` | An empty slot, said plainly. |
| `assume_init()` (unsafe) | `get()` -> `Option[T]` | The unsafe "trust me" call becomes an ordinary Option-returning `get` — the protocol verb, with absence meaning "nobody filled it". Checked in debug, free in release. |
| `write(value)` | `fill(u, value)` | Pairs with `Unfilled`, and leaves `write` free for the sink/stream meaning it has everywhere else. |
| `Zeroizing<T>` / "zeroize" | `Scrubbed[T]` / `scrub` | "Zeroize" is a crypto-vendor word. "Scrub" is what you'd say out loud, and works as both noun-ish wrapper and verb. |
| `replace(dest, src)` | `swapIn(target, value)` | `replace` is overloaded in every language's string API. `swapIn` says the old value comes back. |
| `take(dest)` | `takeOut(target)` | `take` alone reads like `iter.take(n)`. |
| `forget(x)` | `disown(x)` | "Forget" sounds accidental. "Disown" sounds like the deliberate ownership transfer it is. |
| `size_of::<T>()` | `sizeOf(T)` | Nim's `sizeof` under a camelCase name matching `alignOf`. |

## In use

```nim
# secrets-vault: the decrypted vault exists briefly and is wiped on the way out
proc unlock(path: TextView, passphrase: var Scrubbed[array[64, byte]]): Scrubbed[VaultBody] =
  var plain = scrubbed(decrypt(readVault(path), passphrase.value))
  passphrase.value.scrub()        # gone the moment it's no longer needed
  result = plain                  # wiped automatically when the caller drops it

# embedded-sensor-node: a register buffer the I2C engine fills, not us
var raw = blank(array[6, byte])
bus.readInto(sensorAddr, raw.addressOf(), timeout = 10.ms)
raw.get().ifSome(bytes): filter.push(bytes.tryTo(Reading).get(lastGood))
```

## Vocabulary exceptions
`swap`, `swapIn`, `takeOut`, `fill`, `scrub` and `disown` are domain verbs; the structural table has no vocabulary for moving values between locations without a collection involved. All take their target first. `get` is used in its protocol sense on `Unfilled[T]` even though there's no locator argument — the return type (`Option`) and the meaning ("might not be there") are exactly the protocol's, so reusing the word is more informative than inventing one.
