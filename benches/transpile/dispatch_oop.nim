# The same dispatch written the OTHER way a Nim programmer might: inheritance
# and dynamic dispatch. Not what Tuck emits — this is the reference point that
# says what the tagged-variant design BUYS.
type
  Shape = ref object of RootObj
  Circle = ref object of Shape
    r: int
  Rect = ref object of Shape
    w, h: int
  Tri = ref object of Shape
    b, th: int

method area(s: Shape): int {.base.} = 0
method area(s: Circle): int = (s.r * s.r) * 3
method area(s: Rect): int = s.w * s.h
method area(s: Tri): int = (s.b * s.th) div 2

proc one(i: int): Shape =
  let m = i mod 3
  if m == 0: return Circle(r: i mod 97)
  if m == 1: return Rect(w: i mod 89, h: 3)
  return Tri(b: i mod 83, th: 4)

proc main(): int =
  var acc = 0
  for i in 0 ..< 40000000:
    acc = acc + area(one(i))
  return acc mod 251

when isMainModule:
  quit(main())
