# The natural hand-written Nim for the same kernel.
proc mix(a: int, b: int): int =
  return (a * 3) + (b mod 7)

proc main(): int =
  var acc = 0
  for i in 0 ..< 60000000:
    acc = acc + mix(i, acc)
  return acc mod 251

when isMainModule:
  quit(main())
