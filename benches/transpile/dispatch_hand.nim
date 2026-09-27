type
  ShapeTag = enum Circle, Rect, Tri
    ## Which variant a Shape holds.
  Shape = object
    ## A shape as a tagged case object — the hand-written form of what Tuck's
    ## sum types emit.
    case tag: ShapeTag
    of Circle: r: int
    of Rect: w, h: int
    of Tri: b, th: int

proc area(s: Shape): int =
  ## Dispatch by `case` on the tag: no indirection, no allocation.
  case s.tag
  of Circle: return (s.r * s.r) * 3
  of Rect: return s.w * s.h
  of Tri: return (s.b * s.th) div 2

proc one(i: int): int =
  ## Builds the `i`th shape (cycling through the three) and returns its area.
  let m = i mod 3
  if m == 0:
    return area(Shape(tag: Circle, r: i mod 97))
  if m == 1:
    return area(Shape(tag: Rect, w: i mod 89, h: 3))
  return area(Shape(tag: Tri, b: i mod 83, th: 4))

proc main(): int =
  ## The kernel: sums 40M areas, reduced mod 251 so the exit code checks it.
  var acc = 0
  for i in 0 ..< 40000000:
    acc = acc + one(i)
  return acc mod 251

when isMainModule:
  quit(main())
