## `interface` — a compile-time contract (spec §5.2).
##
## Phase 1: the declaration and the check. An interface names a set of function
## signatures; an object declares `satisfies I` in its body and the compiler
## verifies it implements every one of them. No dispatch, no collections — those
## depend on a decision (heterogeneous `Seq[Animal]` or contract-only) that is
## deliberately still open, and nothing here forecloses it.
##
## Conformance rules:
##   - params and return match EXACTLY, names included (payload fields bind by
##     name, so a name is part of the contract)
##   - effects may be a SUBSET: an impl may do less than the contract permits,
##     never more
##   - `Self` in a required sig means the INTERFACE (R13, ruled 2026-09-27),
##     except in the receiver `self`, which is the object running; `-> Self`
##     may be implemented as the object's own type (covariant)

import ../harness

proc run*(t: var T) =
  ## Registers the `interface` contract assertions: declarations, `satisfies`
  ## checks and the conformance error when a member is missing or mismatched.
  # --- conformance passes ---------------------------------------------------

  t.src """
interface Speaker:
  fn speak({volume: int}) -> str

object Dog:
  satisfies Speaker
  name: str

  fn speak({volume: int}) -> str:
    return self.name

fn main() -> int:
  return 0
"""
  t.okCheck "an object implementing every member satisfies"

  # Several interfaces on one object — it is a seq of names, not a single slot.
  t.src """
interface Speaker:
  fn speak({volume: int}) -> str

interface Named:
  fn label() -> str

object Dog:
  satisfies Speaker
  satisfies Named
  name: str

  fn speak({volume: int}) -> str:
    return self.name
  fn label() -> str:
    return self.name

fn main() -> int:
  return 0
"""
  t.okCheck "one object may satisfy several interfaces"

  # Effects SUBSET: the contract permits [io], the impl is pure. Legal — an
  # implementation may do less than the contract allows.
  t.src """
interface Loader:
  fn load({path: str}) -> str [io]

object Cache:
  satisfies Loader
  data: str

  fn load({path: str}) -> str:
    return self.data

fn main() -> int:
  return 0
"""
  t.okCheck "an impl may declare fewer effects than the contract"

  # `Self` in the contract reads as the implementing type.
  t.src """
interface Cloneable:
  fn copyOf() -> Self

object Doc:
  satisfies Cloneable
  n: int

  fn copyOf() -> Doc:
    return self

fn main() -> int:
  return 0
"""
  t.okCheck "Self in a required sig means the implementing type"

  # An interface nobody satisfies is still a legal declaration.
  t.src """
interface Storable:
  fn save({dest: str}) -> int

fn main() -> int:
  return 0
"""
  t.okCheck "an unsatisfied interface is legal"

  # --- conformance fails, with a message worth reading ----------------------

  t.src """
interface Speaker:
  fn speak({volume: int}) -> str

object Mime:
  satisfies Speaker
  name: str

fn main() -> int:
  return 0
"""
  t.badCheck "a missing member is reported", "speak"

  # The parameter NAME is part of the contract: payload fields bind by name, so
  # renaming one silently changes how callers must write the call.
  t.src """
interface Speaker:
  fn speak({volume: int}) -> str

object Dog:
  satisfies Speaker
  name: str

  fn speak({loudness: int}) -> str:
    return self.name

fn main() -> int:
  return 0
"""
  t.badCheck "a renamed parameter is reported", "loudness|volume"

  t.src """
interface Speaker:
  fn speak({volume: int}) -> str

object Dog:
  satisfies Speaker
  name: str

  fn speak({volume: str}) -> str:
    return self.name

fn main() -> int:
  return 0
"""
  t.badCheck "a wrong parameter type is reported", "volume"

  t.src """
interface Speaker:
  fn speak({volume: int}) -> str

object Dog:
  satisfies Speaker
  name: str

  fn speak({volume: int}) -> int:
    return 1

fn main() -> int:
  return 0
"""
  t.badCheck "a wrong return type is reported", "return|str|int"

  # Effects the other way: the contract is pure, the impl wants [io]. Illegal —
  # an implementation may never do MORE than the contract permits.
  t.src """
interface Pure:
  fn compute({n: int}) -> int

object Logger:
  satisfies Pure

  fn compute({n: int}) -> int [io]:
    return n

fn main() -> int:
  return 0
"""
  t.badCheck "an impl may not declare effects the contract lacks", "io|effect"

  t.src """
object Dog:
  satisfies NoSuchInterface
  name: str

  fn speak({volume: int}) -> str:
    return self.name

fn main() -> int:
  return 0
"""
  t.badCheck "satisfying an undeclared interface is reported", "NoSuchInterface"

  # A body-less member does not implement anything — it is a signature, and the
  # object would have no code to run.
  t.src """
interface Speaker:
  fn speak({volume: int}) -> str

object Dog:
  satisfies Speaker
  name: str

  fn speak({volume: int}) -> str

fn main() -> int:
  return 0
"""
  t.badCheck "a body-less member does not implement the contract", "speak"

  # --- top-level `Obj satisfies Iface` --------------------------------------
  #
  # A CALLING module attaches an object it did not declare to a contract it did
  # not declare, so a library type can be used through your interface without
  # editing the library.

  t.src """
import sys

interface Speaker:
  fn noise({self: Self}) -> int

interface Mover:
  fn steps({self: Self}) -> int

object Dog:
  name: str
  fn noise({self: Dog}) -> int:
    return 1
  fn steps({self: Dog}) -> int:
    return 4

object Cat:
  satisfies Speaker
  name: str
  fn noise({self: Cat}) -> int:
    return 41
  fn steps({self: Cat}) -> int:
    return 0

satisfies Dog: Speaker, Mover
satisfies Cat: Speaker, Mover

fn hear({a: Speaker}) -> int:
  return a.noise

fn main() -> void [io]:
  let d = {name: "rex"} Dog
  let c = {name: "tom"} Cat
  let total = {a: d} hear + {a: c} hear
  total sys::exit
"""
  t.runs "a top-level satisfies attaches an object to a contract", 42

  # Re-stating a contract the object already declares is a NO-OP, not an error:
  # a calling module cannot know what the library already promised. (Cat above
  # declares `satisfies Speaker` in its body AND is listed again at top level.)

  t.src """
interface Speaker:
  fn noise({self: Self}) -> int

object Dog:
  name: str

satisfies Dog: Speaker

fn main() -> int:
  return 0
"""
  t.badCheck "an attached contract is still enforced", "does not implement"

  t.src """
interface Speaker:
  fn noise({self: Self}) -> int

satisfies Ghost: Speaker

fn main() -> int:
  return 0
"""
  t.badCheck "attaching to an undeclared object is reported",
             "not declared in this module"

  # --- contracts come before fields -----------------------------------------
  #
  # What an object PROMISES should be visible before its data, so a body reads
  # "what is this for" before "what does it hold" and the promise cannot hide
  # below a long field list.

  t.src """
interface Speaker:
  fn noise({self: Self}) -> int

object Dog:
  name: str
  satisfies Speaker
  fn noise({self: Dog}) -> int:
    return 1

fn main() -> int:
  return 0
"""
  t.badCheck "a satisfies line after a field is rejected", "before the object's fields"

  # --- satisfies on something that is not an object -------------------------
  #
  # The refusal is correct in all four cases — a contract is recorded on an
  # object's declaration and dispatch reads it from there. What was wrong was
  # the message: "not a declared object in scope" fits a TYPO and nothing
  # else, so an author who wrote `satisfies int:` deliberately went looking
  # for a declaration they never omitted. (FRICTIONS #6.)

  const ifaceSrc = """
interface Hashable:
  fn hash({item: Self}) -> int
"""

  t.src ifaceSrc & """
satisfies int: Hashable

fn main() -> int:
  return 0
"""
  t.badCheck "satisfies on a primitive says it is a primitive",
             "'int' is a primitive"

  t.src ifaceSrc & """
type Point = {x: int, y: int}
satisfies Point: Hashable

fn main() -> int:
  return 0
"""
  t.badCheck "satisfies on a `type` record says to use an object",
             "declare it as an `object` instead"

  t.src ifaceSrc & """
interface Other:
  fn go({item: Self}) -> int
satisfies Other: Hashable

fn main() -> int:
  return 0
"""
  t.badCheck "satisfies on an interface says a contract is not a subject",
             "is an interface"

  # --- what `Self` means in a contract (R13 = B, ruled 2026-09-27) ----------

  # Outside the receiver, `Self` is the interface: an implementation takes
  # `next: AudioSource`, because a caller holding only an interface value
  # may pass any satisfier — an MP3 crossfades into a FLAC.
  const audioSrc = """
interface AudioSource:
  fn sampleRate({self: Self}) -> int
  fn crossfade({self: Self, next: Self, ms: int}) -> int

object Mp3:
  satisfies AudioSource
  bitrate: int
  fn sampleRate({self: Mp3}) -> int:
    return 44100
  fn crossfade({self: Mp3, next: AudioSource, ms: int}) -> int:
    return (ms * 44) + (ms * (next.sampleRate /i 1000))

"""
  t.src audioSrc & """
object Flac:
  satisfies AudioSource
  bits: int
  fn sampleRate({self: Flac}) -> int:
    return 96000
  fn crossfade({self: Flac, next: AudioSource, ms: int}) -> int:
    return (ms * 96) + (ms * (next.sampleRate /i 1000))

fn transition({cur: AudioSource, next: AudioSource}) -> int:
  return cur.crossfade {next: next, ms: 1}

fn main() -> int:
  return 0
"""
  t.okCheck "a non-receiver `Self` is implemented as the interface"

  # ...and through an interface value a concrete `Flac` held in a local is
  # wrapped into that `Self` slot. The local `ms` is the A22 shape: Odin's
  # dispatch closure takes the arguments as parameters.
  t.src audioSrc & """
object Flac:
  satisfies AudioSource
  bits: int
  fn sampleRate({self: Flac}) -> int:
    return 96000
  fn crossfade({self: Flac, next: AudioSource, ms: int}) -> int:
    return (ms * 96) + (ms * (next.sampleRate /i 1000))

fn transition({cur: AudioSource, f: Flac}) -> int:
  let ms = 1
  return cur.crossfade {next: f, ms: ms}

fn main() -> int:
  let m = Mp3{bitrate: 320}
  let f = Flac{bits: 24}
  return {cur: m, f: f} transition
"""
  t.hostRuns "an MP3 crossfades into a FLAC through the interface, on every backend", 140

  t.src audioSrc & """
object Flac:
  satisfies AudioSource
  bits: int
  fn sampleRate({self: Flac}) -> int:
    return 96000
  fn crossfade({self: Flac, next: Flac, ms: int}) -> int:
    return ms

fn main() -> int:
  return 0
"""
  t.badCheck "...and narrowing it to the object's own type is refused",
             "`Self` outside the receiver means the interface"

  # `-> Self` accepts either the interface or the object's own type; any
  # other object is refused.
  t.src """
interface Shape:
  fn grown({self: Self}) -> Self

object Sq:
  satisfies Shape
  s: int
  fn grown({self: Sq}) -> Shape:
    return self

fn main() -> int:
  return 0
"""
  t.okCheck "`-> Self` may be implemented as `-> Shape`"

  t.src """
interface Shape:
  fn grown({self: Self}) -> Self

object Ci:
  r: int

object Sq:
  satisfies Shape
  s: int
  fn grown({self: Sq}) -> Ci:
    return Ci{r: self.s}

fn main() -> int:
  return 0
"""
  t.badCheck "...but not as another object", "the contract declares Shape or Sq"

  # A call through an interface value is checked against the contract like
  # any call. Neither of these was: both checked clean, and the second
  # tripped an assertion in lowering. Found 2026-09-27.
  t.src audioSrc & """
fn transition({cur: AudioSource, next: AudioSource}) -> int:
  return cur.crossfade {next: next, ms: "x"}

fn main() -> int:
  return 0
"""
  t.badCheck "an interface call's argument of the wrong type is refused",
             "field 'ms' of call to 'crossfade' expects int but got str"

  t.src audioSrc & """
fn transition({cur: AudioSource}) -> int:
  return cur.crossfade {ms: 1}

fn main() -> int:
  return 0
"""
  t.badCheck "an interface call missing a field is refused",
             "missing required field 'next: AudioSource'"

  # --- same object type: type params bounded by `Self` ----------------------

  # `fn splice[A: Self, B: Self]({self: A, other: A, next: B})`: `other` is
  # the receiver's own object type, `next` any satisfier. An implementation
  # writes the concrete types. Ruled 2026-09-27; compile-time only.
  const spliceIface = """
interface AudioSource:
  fn sampleRate({self: Self}) -> int
  fn splice[A: Self, B: Self]({self: A, other: A, next: B}) -> int

object Mp3:
  satisfies AudioSource
  bitrate: int
  fn sampleRate({self: Mp3}) -> int:
    return 44100
  fn splice({self: Mp3, other: Mp3, next: AudioSource}) -> int:
    return self.bitrate + other.bitrate + (next.sampleRate /i 1000)

"""
  t.src spliceIface & """
object Flac:
  satisfies AudioSource
  bits: int
  fn sampleRate({self: Flac}) -> int:
    return 96000
  fn splice({self: Flac, other: Flac, next: AudioSource}) -> int:
    return self.bits + other.bits + (next.sampleRate /i 1000)

fn main() -> int:
  let a = Flac{bits: 24}
  let b = Flac{bits: 16}
  let m = Mp3{bitrate: 3}
  return a.splice {other: b, next: m}
"""
  t.okCheck "`[A: Self, B: Self]`: `other: A` is the object, `next: B` the interface"
  t.hostRuns "...and a call on a concrete object runs, on every backend", 84

  t.src spliceIface & """
object Flac:
  satisfies AudioSource
  bits: int
  fn sampleRate({self: Flac}) -> int:
    return 96000
  fn splice({self: Flac, other: AudioSource, next: AudioSource}) -> int:
    return self.bits

fn main() -> int:
  return 0
"""
  t.badCheck "the receiver's letter is the object's own type, not the interface",
             "parameter 'other' is AudioSource, the contract declares Flac"

  t.src spliceIface & """
fn joinAny({a: AudioSource, b: AudioSource}) -> int:
  return a.splice {other: b, next: b}

fn main() -> int:
  return 0
"""
  t.badCheck "through an interface value a same-type member is TK-TY33", "TK-TY33"

  # A letter the receiver does not use is any satisfier, so such a member is
  # callable through an interface value.
  t.src """
interface AudioSource:
  fn sampleRate({self: Self}) -> int
  fn mix[B: Self]({self: Self, next: B}) -> int

object Mp3:
  satisfies AudioSource
  bitrate: int
  fn sampleRate({self: Mp3}) -> int:
    return 44100
  fn mix({self: Mp3, next: AudioSource}) -> int:
    return self.bitrate + (next.sampleRate /i 1000)

object Flac:
  satisfies AudioSource
  bits: int
  fn sampleRate({self: Flac}) -> int:
    return 96000
  fn mix({self: Flac, next: AudioSource}) -> int:
    return self.bits + (next.sampleRate /i 1000)

fn both({a: AudioSource, b: AudioSource}) -> int:
  return a.mix {next: b}

fn main() -> int:
  let m = Mp3{bitrate: 3}
  let f = Flac{bits: 24}
  return {a: f, b: m} both
"""
  t.hostRuns "`[B: Self]` off the receiver is callable through the interface", 68

  # --- renaming a contract member: `satisfies I {old -> new}` ---------------

  # Two interfaces that each require a `noise`, with different return types:
  # one object cannot hold two members named `noise`, so it implements
  # `Machine.noise` as `hum`. A call through a `Machine` reaches `hum`; a call
  # through an `Animal` reaches `noise`. `old -> new` is the rename spelling
  # everywhere (TK-PA17). Ruled 2026-09-27.
  t.src """
interface Animal:
  fn noise({self: Self}) -> int

interface Machine:
  fn noise({self: Self}) -> str

object Robodog:
  satisfies Animal
  satisfies Machine {noise -> hum}
  bark: int
  fn noise({self: Robodog}) -> int:
    return self.bark
  fn hum({self: Robodog}) -> str:
    return "bzz"

object Toaster:
  satisfies Machine
  heat: int
  fn noise({self: Toaster}) -> str:
    return "ding"

fn animalNoise({a: Animal}) -> int:
  return a.noise

fn machineNoise({m: Machine}) -> str:
  return m.noise

fn main() -> int:
  let r = Robodog{bark: 7}
  let t = Toaster{heat: 1}
  let s = ({m: r} machineNoise) + ({m: t} machineNoise)
  return ({a: r} animalNoise) + s.len
"""
  t.okCheck "`satisfies Machine {noise -> hum}` implements noise as hum"
  t.hostRuns "each interface reaches its own member, on every backend", 14

  t.src """
interface Machine:
  fn noise({self: Self}) -> str

object Robodog:
  satisfies Machine {nois -> hum}
  fn hum({self: Robodog}) -> str:
    return "bzz"

fn main() -> int:
  return 0
"""
  t.badCheck "renaming a member the interface lacks is TK-CO04",
             "TK-CO04"

  t.src """
interface Machine:
  fn noise({self: Self}) -> str

object Robodog:
  satisfies Machine {noise -> hum}
  fn noise({self: Robodog}) -> str:
    return "bzz"

fn main() -> int:
  return 0
"""
  t.badCheck "the renamed member must exist under its new name",
             "under the name 'hum'"

  # The top-level form takes the same list, after each interface it names.
  t.src """
interface Machine:
  fn noise({self: Self}) -> str

object Robodog:
  bark: int
  fn hum({self: Robodog}) -> str:
    return "bzz"

satisfies Robodog: Machine {noise -> hum}

fn machineNoise({m: Machine}) -> str:
  return m.noise

fn main() -> int:
  let r = Robodog{bark: 7}
  return ({m: r} machineNoise).len
"""
  t.okCheck "`satisfies Obj: I {old -> new}` renames at the top level too"
  t.hostRuns "...and dispatch reaches the renamed member", 3

  # --- the existing example must stay honest --------------------------------

  # examples/04-sum-types-interface.tuck declares `interface Storable` with a
  # bare body (no `require:`), which is exactly the shape spec §5.2 now
  # specifies. Nothing satisfies it, which stays legal.
  let ex04 = t.needCmd @["./tuck", "ch", "examples/04-sum-types-interface.tuck",
                         "--root:" & t.root]
  if t.phase == pReport:
    let (rc, outp) = t.resultOf(ex04)
    if rc == 0: t.ok "examples/04 still checks"
    else: t.no "examples/04 still checks", outp

  t.finish()
