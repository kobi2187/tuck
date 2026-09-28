# The natural hand-written Nim for the same kernel.
proc mix(a: int, b: int): int =
  ## One step of the kernel, taking its two ints as plain parameters — the
  ## shape a Tuck payload call lowers to.
  return (a * 3) + (b mod 7)

proc main(): int =
  ## The kernel: folds 60M calls, reduced mod 251 so the exit code checks it.
  var acc = 0
  for i in 0 ..< 60000000:
    acc = acc + mix(i, acc)
  return acc mod 251

when isMainModule:
  quit(main())
