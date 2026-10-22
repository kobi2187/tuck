# Nim impl module for stdlib-project sys.mmap — the twins are mmap_shim.odin
# and mmap_shim.d, beside this file.
#
# The mapping's address never crosses into Tuck: Tuck may not hold a pointer.
# What crosses is a HANDLE, an index into this table, and every operation on
# the mapped bytes runs here, where reading through a pointer is ordinary.
# Only `mapCopy` hands bytes over, and only the window asked for.
#
# The table is process-global and not locked: a mapping is used from the thread
# that opened it (the scheduler's), as the rest of the runtime's handles are.
import std/posix

type Mapping = object
  base: ptr UncheckedArray[uint8]
  size: int
  live: bool

var gMaps: seq[Mapping]

proc errnoCode(): int =
  ## The failure as the Tuck module reads it: -1 not found, -2 access denied,
  ## -3 anything else.
  let e = posix.errno
  if e == ENOENT or e == ENOTDIR: -1
  elif e == EACCES or e == EPERM: -2
  else: -3

proc valid(handle: int): bool =
  handle >= 0 and handle < gMaps.len and gMaps[handle].live

proc mapOpen*(path: string): int =
  ## A read-only, private mapping of the whole file: a handle >= 0, or a
  ## negative code. An empty file maps to no memory at all (mmap refuses a
  ## zero length) and reads as zero bytes.
  let fd = posix.open(path.cstring, O_RDONLY)
  if fd < 0: return errnoCode()
  var st: Stat
  if fstat(fd, st) != 0:
    let c = errnoCode()
    discard close(fd)
    return c
  let size = int(st.st_size)
  var base: pointer = nil
  if size > 0:
    base = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0)
    if base == MAP_FAILED:
      let c = errnoCode()
      discard close(fd)
      return c
  # the mapping keeps the file's pages reachable; the descriptor is not needed
  discard close(fd)
  gMaps.add Mapping(base: cast[ptr UncheckedArray[uint8]](base), size: size,
                    live: true)
  gMaps.high

proc mapSize*(handle: int): int =
  if not valid(handle): return -1
  gMaps[handle].size

proc mapClose*(handle: int) =
  if not valid(handle): return
  if gMaps[handle].size > 0:
    discard munmap(gMaps[handle].base, gMaps[handle].size)
  gMaps[handle].live = false

proc mapByte*(handle, at: int): int =
  ## The byte at `at`, or -1 outside the mapping.
  if not valid(handle) or at < 0 or at >= gMaps[handle].size: return -1
  int(gMaps[handle].base[at])

proc mapFind*(handle: int, what: string, start: int): int =
  ## The first offset >= `start` where `what` begins, or -1.
  if not valid(handle) or what.len == 0: return -1
  let m = gMaps[handle]
  var i = max(start, 0)
  while i + what.len <= m.size:
    if m.base[i] == uint8(what[0]):
      var k = 1
      while k < what.len and m.base[i + k] == uint8(what[k]): inc k
      if k == what.len: return i
    inc i
  -1

proc mapCount*(handle, value: int): int =
  ## How many bytes equal `value`.
  if not valid(handle): return 0
  let m = gMaps[handle]
  for i in 0 ..< m.size:
    if int(m.base[i]) == value: inc result

proc mapCountRange*(handle, value, start, n: int): int =
  ## How many bytes in [start, start + n) equal `value`, clamped.
  if not valid(handle): return 0
  let m = gMaps[handle]
  for i in max(start, 0) ..< min(start + n, m.size):
    if int(m.base[i]) == value: inc result

proc mapCopy*(handle, start, n: int): seq[uint8] =
  ## A copy of [start, start + n), clamped to the mapping.
  if not valid(handle): return @[]
  let m = gMaps[handle]
  let a = max(start, 0)
  let b = min(start + n, m.size)
  for i in a ..< b: result.add m.base[i]
