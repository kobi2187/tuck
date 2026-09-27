type Reading = object
  ## A six-field record passed by value, as Tuck's records are.
  a, b, c, d, e, f: int

proc score(r: Reading): int =
  ## Reads three of the record's fields.
  return (r.a + r.c) + (r.e mod 13)

proc main(): int =
  ## The kernel: builds and scores 40M records, reduced mod 251.
  var acc = 0
  for i in 0 ..< 40000000:
    let r = Reading(a: i, b: 2, c: acc mod 977, d: 4, e: i, f: 6)
    acc = acc + score(r)
  return acc mod 251

when isMainModule:
  quit(main())
