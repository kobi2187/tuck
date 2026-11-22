# The one print shim both loops use. On metal the runtime routes a string to
# ARM semihosting (`tuck_semihost_write`, defined in boards/semihost.s); on the
# host there is no such symbol, so stdout is the same observable surface.
# Gating on `freestanding` keeps the QEMU build byte-for-byte unchanged.
when defined(freestanding):
  proc tuckSemihostWrite(s: cstring) {.importc: "tuck_semihost_write".}
  proc say*(s: string) =
    tuckSemihostWrite(s.cstring)
else:
  proc say*(s: string) =
    stdout.write(s)
