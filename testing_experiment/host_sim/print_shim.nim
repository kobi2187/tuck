# Freestanding print: route a Tuck string to ARM semihosting.
proc tuckSemihostWrite(s: cstring) {.importc: "tuck_semihost_write".}
proc say*(s: string) =
  tuckSemihostWrite(s.cstring)
