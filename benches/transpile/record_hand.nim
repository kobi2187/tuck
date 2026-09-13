type Reading = object
  a, b, c, d, e, f: int

proc score(r: Reading): int =
  return (r.a + r.c) + (r.e mod 13)

proc main(): int =
  var acc = 0
  for i in 0 ..< 40000000:
    let r = Reading(a: i, b: 2, c: acc mod 977, d: 4, e: i, f: 6)
    acc = acc + score(r)
  return acc mod 251

when isMainModule:
  quit(main())
