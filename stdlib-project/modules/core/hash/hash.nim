{.experimental: "codeReordering".}
import ../../../../compiler/tuck_rt
import bits
import str

proc tuck_fnvOffsetBasis*(): uint64
proc tuck_fnvPrime*(): uint64
proc tuck_fnvStep*(acc: uint64, octet: uint64): uint64
proc tuck_hashStr*(data: string): uint64
proc tuck_combine*(a: uint64, b: uint64): uint64
proc tuck_main*(): int

proc tuck_fnvOffsetBasis*(): uint64 =
  return 14695981039346656037'u64

proc tuck_fnvPrime*(): uint64 =
  return 1099511628211'u64

proc tuck_fnvStep*(acc: uint64, octet: uint64): uint64 =
  var tuck_mixed = tuck_rt.bitXor(acc, octet)
  return (tuck_mixed * tuck_fnvPrime())

proc tuck_hashStr*(data: string): uint64 =
  var tuck_h = tuck_fnvOffsetBasis()
  for tuck_i in (0 .. (tuck_rt.byteCount(data) - 1)):
    if true:
      var tuck_b = tuck_rt.byteAt(data, tuck_i)
      var tuck_octet = uint64(tuck_b)
      tuck_h = tuck_fnvStep(tuck_h, tuck_octet)
  return tuck_h

proc tuck_combine*(a: uint64, b: uint64): uint64 =
  return tuck_fnvStep(a, b)

proc tuck_main*(): int =
  if (tuck_hashStr("") != tuck_fnvOffsetBasis()):
    if true:
      return 1
  var tuck_a = tuck_hashStr("hello")
  var tuck_b = tuck_hashStr("world")
  if (tuck_a == tuck_b):
    if true:
      return 2
  if (tuck_a != tuck_hashStr("hello")):
    if true:
      return 3
  if (tuck_hashStr("ab") == tuck_hashStr("ba")):
    if true:
      return 4
  return 0


when isMainModule:
  quit(tuck_main())
