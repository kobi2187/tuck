{.experimental: "codeReordering".}
import ../../../../compiler/tuck_rt
import bits
import str
import seq as tuck_mod_seq

proc tuck_fnvOffsetBasis*(): uint64
proc tuck_fnvPrime*(): uint64
proc tuck_fnvStep*(acc: uint64, octet: uint64): uint64
proc tuck_hashBytes*(data: seq[uint8]): uint64
proc tuck_strBytes*(t: string): seq[uint8]
proc tuck_hashStr*(data: sink string): uint64
proc tuck_u64Bytes*(x: uint64): seq[uint8]
proc tuck_hashU64*(x: uint64): uint64
proc tuck_combine*(a: uint64, b: uint64): uint64
proc tuck_checkHashBytes*(): int
proc tuck_checkHashU64*(): int
proc tuck_main*(): int

proc tuck_fnvOffsetBasis*(): uint64 =
  return 14695981039346656037'u64

proc tuck_fnvPrime*(): uint64 =
  return 1099511628211'u64

proc tuck_fnvStep*(acc: uint64, octet: uint64): uint64 =
  var tuck_mixed = tuck_rt.bitXor(acc, octet)
  return (tuck_mixed * tuck_fnvPrime())

proc tuck_hashBytes*(data: seq[uint8]): uint64 =
  var tuck_h = tuck_fnvOffsetBasis()
  for tuck_i in (0 .. (getLength(data) - 1)):
    if true:
      var tuck_octet = uint64(tuck_rt.tuckAt(data, tuck_i))
      tuck_h = tuck_fnvStep(tuck_h, tuck_octet)
  return tuck_h

proc tuck_strBytes*(t: string): seq[uint8] =
  var tuck_out: seq[uint8] = @[]
  for tuck_i in (0 .. (tuck_rt.byteCount(t) - 1)):
    if true:
      var tuck_b = tuck_rt.byteAt(t, tuck_i)
      tuck_out.add(tuck_b)
  return tuck_out

proc tuck_hashStr*(data: sink string): uint64 =
  var tuck_bytes = tuck_strBytes(data)
  return tuck_hashBytes(tuck_bytes)

proc tuck_u64Bytes*(x: uint64): seq[uint8] =
  var tuck_out: seq[uint8] = @[]
  var tuck_i = 0
  while (tuck_i < 8):
    if true:
      var tuck_shifted = tuck_rt.shiftRight(x, (tuck_i * 8))
      var tuck_octet = tuck_rt.bitAnd(tuck_shifted, 255'u64)
      var tuck_b = uint8(tuck_octet)
      tuck_out.add(tuck_b)
      tuck_i = (tuck_i + 1)
  return tuck_out

proc tuck_hashU64*(x: uint64): uint64 =
  var tuck_bytes = tuck_u64Bytes(x)
  return tuck_hashBytes(tuck_bytes)

proc tuck_combine*(a: uint64, b: uint64): uint64 =
  return tuck_fnvStep(a, b)

proc tuck_checkHashBytes*(): int =
  var tuck_empty: seq[uint8] = @[]
  if (tuck_hashBytes(tuck_empty) != tuck_fnvOffsetBasis()):
    if true:
      return 5
  return 0

proc tuck_checkHashU64*(): int =
  if (tuck_hashU64(0'u64) != tuck_hashU64(0'u64)):
    if true:
      return 10
  var tuck_a = tuck_hashU64(1'u64)
  var tuck_b = tuck_hashU64(2'u64)
  if (tuck_a == tuck_b):
    if true:
      return 11
  if (tuck_a != tuck_hashU64(1'u64)):
    if true:
      return 12
  if (tuck_hashU64(1'u64) == tuck_hashU64(256'u64)):
    if true:
      return 13
  return 0

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
  var tuck_bytes = tuck_checkHashBytes()
  if (tuck_bytes != 0):
    if true:
      return tuck_bytes
  return tuck_checkHashU64()


when isMainModule:
  quit(tuck_main())
