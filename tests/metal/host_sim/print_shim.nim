# The one print shim both loops use. On metal the runtime routes a string to
# the board's console (`tuck_board_puts`: semihosting under QEMU, boards/common/
# semihosting.c; a UART on a real board); on the
# host there is no such symbol, so stdout is the same observable surface.
# Gating on `freestanding` keeps the QEMU build byte-for-byte unchanged.
when defined(freestanding):
  proc tuckSemihostWrite(s: cstring) {.importc: "tuck_board_puts".}
  proc say*(s: string) =
    tuckSemihostWrite(s.cstring)
else:
  proc say*(s: string) =
    stdout.write(s)
