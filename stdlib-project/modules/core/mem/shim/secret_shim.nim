# Nim impl module for core.mem's secret buffers — twins: secret_shim.odin and
# secret_shim.d. A secret lives HERE, in memory the shim allocates, locks
# against swapping (mlock) and wipes with explicit_bzero, a write the optimiser
# may not remove. Tuck holds a HANDLE. Nothing in a Seq is ever the secret
# unless the caller copies it out (`secretGet`), which is their decision.
import std/posix

proc explicit_bzero(p: pointer, n: csize_t) {.importc, header: "<string.h>".}

type Secret = object
  data: ptr UncheckedArray[uint8]
  len: int
  live: bool

var gSecrets: seq[Secret]

proc valid(h: int): bool = h >= 0 and h < gSecrets.len and gSecrets[h].live

proc secretNew*(n: int): int =
  ## A zeroed, locked buffer of n bytes; its handle.
  let size = max(n, 1)
  let p = cast[ptr UncheckedArray[uint8]](allocShared0(size))
  discard mlock(p, size)
  gSecrets.add Secret(data: p, len: n, live: true)
  gSecrets.len - 1

proc secretLen*(h: int): int =
  if not valid(h): return 0
  gSecrets[h].len

proc secretSet*(h, i, v: int) =
  if not valid(h) or i < 0 or i >= gSecrets[h].len: return
  gSecrets[h].data[i] = uint8(v and 255)

proc secretGet*(h, i: int): int =
  if not valid(h) or i < 0 or i >= gSecrets[h].len: return 0
  int gSecrets[h].data[i]

proc secretWipe*(h: int) =
  ## Overwrite (unremovably), unlock, free. The handle is dead afterwards.
  if not valid(h): return
  let size = max(gSecrets[h].len, 1)
  explicit_bzero(gSecrets[h].data, csize_t(size))
  discard munlock(gSecrets[h].data, size)
  deallocShared(gSecrets[h].data)
  gSecrets[h].live = false
  gSecrets[h].len = 0
