# The same dispatch written the OTHER way a Nim programmer might: inheritance
# and dynamic dispatch. Not what Tuck emits — this is the reference point that
# says what the tagged-variant design BUYS.
type
  Shape = ref object of RootObj
    ## The base of the shape hierarchy: a ref object, one heap allocation per
    ## shape, dispatched through methods.
  Circle = ref object of Shape
    ## A circle subtype, heap-allocated.
    r: int
  Rect = ref object of Shape
    ## A rectangle subtype, heap-allocated.
    w, h: int
  Tri = ref object of Shape
    ## A triangle subtype, heap-allocated.
    b, th: int

method area(s: Shape): int {.base.} =
  ## The base method; never reached, since every shape is a subtype.
  0
method area(s: Circle): int =
  ## A circle's area (with pi taken as 3).
  (s.r * s.r) * 3
method area(s: Rect): int =
  ## A rectangle's area.
  s.w * s.h
method area(s: Tri): int =
  ## A triangle's area.
  (s.b * s.th) div 2

proc one(i: int): Shape =
  ## Allocates the `i`th shape (cycling through the three subtypes).
  let m = i mod 3
  if m == 0: return Circle(r: i mod 97)
  if m == 1: return Rect(w: i mod 89, h: 3)
  return Tri(b: i mod 83, th: 4)

proc main(): int =
  ## The same kernel as dispatch_hand, through dynamic dispatch.
  var acc = 0
  for i in 0 ..< 40000000:
    acc = acc + area(one(i))
  return acc mod 251

when isMainModule:
  quit(main())
