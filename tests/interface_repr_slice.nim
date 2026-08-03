# tests/interface_repr_slice.nim
#
# A vertical slice of the TAG-VARIANT representation for interface values,
# hand-written as the target output codegen should produce.
#
# Not wired to the compiler: this is the spec for a representation change that
# has not been made yet. Every usage the compiler supports today must be
# expressible in the new shape, and three that are compile errors today must
# become legal.
#
# WHY THIS SHAPE. An interface value is currently {data: pointer, vt} — it
# BORROWS the object, which is why returning one, or storing one in a field,
# is rejected. Copying instead removes every lifetime question, and copy is
# already the rule for every other value in Tuck. So:
#
#   type Animal = object
#     case tag: AnimalTag
#     of atDog: dogVal: Dog
#     of atCat: catVal: Cat
#
# and dispatch is a `case` on the tag calling the concrete member fn directly.
#
# WHY A VARIANT AND NOT A BYTE ARRAY. `array[max(sizeof), byte]` plus copyMem
# was the obvious cheap version, and it is WRONG: Tuck objects hold `str` and
# `Seq`, which are Nim-managed. A byte blit does not adjust the refcount, so
# the source's destructor frees the payload and the copy dangles. Probed under
# ASan — it survived only because ARC happened to MOVE in that shape, which is
# luck, not a guarantee. A variant lets Nim generate the correct copy and
# destroy per branch; Odin's union does the same.
#
# The tag replaces the vtable pointer entirely: no AnimalVT, no thunks, no
# static tables, no demand-driven emission. That is ~600 lines deleted, and the
# closed set the switch needs is exactly what `satisfies` already declares.
#
# Run under ASan, which is how the byte-array version was caught:
#   nim c --mm:arc -d:useMalloc --passC:-fsanitize=address \
#         --passL:-fsanitize=address -r tests/interface_repr_slice.nim
type
  Dog = object
    name: string
  Cat = object
    lives: int
  AnimalTag = enum atDog, atCat
  Animal = object
    case tag: AnimalTag
    of atDog: dogVal: Dog
    of atCat: catVal: Cat

# member fns, as codegen emits them today (self: var T)
proc noise(self: var Dog): int = 1
proc noise(self: var Cat): int = 41
proc label(self: var Dog): string = self.name
proc label(self: var Cat): string = "cat"

# dispatch: a case on the tag, calling the concrete fn directly
proc noise(a: var Animal): int =
  case a.tag
  of atDog: noise(a.dogVal)
  of atCat: noise(a.catVal)
proc label(a: var Animal): string =
  case a.tag
  of atDog: label(a.dogVal)
  of atCat: label(a.catVal)

var failures = 0
proc check(name: string, cond: bool) =
  if cond: echo "PASS  ", name
  else:
    echo "FAIL  ", name
    failures.inc

# 1. interface as a parameter
proc hear(a: var Animal): int = noise(a)
block:
  var d = Animal(tag: atDog, dogVal: Dog(name: "rex"))
  var c = Animal(tag: atCat, catVal: Cat(lives: 9))
  check "param: two types dispatch differently", hear(d) + hear(c) == 42

# 2. MIXED SEQUENCE — the case that matters
block:
  var xs = @[Animal(tag: atDog, dogVal: Dog(name: "rex")),
             Animal(tag: atCat, catVal: Cat(lives: 9))]
  var s = 0
  for x in xs.mitems: s += noise(x)
  check "mixed Seq: each element dispatches to its own impl", s == 42

# 3. RETURNING an interface value made from a LOCAL — was rejected before
proc makeOne(): Animal =
  var d = Dog(name: "local-" & $7)   # a local with a managed field
  Animal(tag: atDog, dogVal: d)      # d dies here; the copy survives
block:
  var a = makeOne()
  var junk: seq[string]
  for i in 0..3000: junk.add("QQQQQQQQ" & $i)   # churn the allocator
  check "return a wrap of a local (copy survives)", label(a) == "local-7"

# 4. returning a Seq of interface values built from locals
proc makeMany(): seq[Animal] =
  var d = Dog(name: "d-" & $1)
  var c = Cat(lives: 9)
  @[Animal(tag: atDog, dogVal: d), Animal(tag: atCat, catVal: c)]
block:
  var xs = makeMany()
  var junk: seq[string]
  for i in 0..3000: junk.add("ZZZZZZZZ" & $i)
  var s = 0
  for x in xs.mitems: s += noise(x)
  check "return a Seq of wraps of locals", s == 42
  check "...and the managed field is intact", label(xs[0]) == "d-1"

# 5. STORED IN A FIELD — was rejected before
type Keeper = object
  pet: Animal
block:
  var k = Keeper(pet: Animal(tag: atDog, dogVal: Dog(name: "kept-" & $3)))
  var junk: seq[string]
  for i in 0..3000: junk.add("WWWWWWWW" & $i)
  check "interface value stored in a field", label(k.pet) == "kept-3"

# 6. copy semantics are OBSERVABLE and consistent
block:
  var d = Dog(name: "orig")
  var a = Animal(tag: atDog, dogVal: d)
  a.dogVal.name = "changed"
  check "mutation through the interface hits the copy", d.name == "orig"
  check "...and the copy has the new value", label(a) == "changed"

# 7. passing an interface value onward
proc outer(a: var Animal): int = hear(a)
block:
  var d = Animal(tag: atDog, dogVal: Dog(name: "x"))
  check "pass an interface value down the call chain", outer(d) == 1

if failures > 0: quit(1)
echo "vertical slice: all usages expressible"
