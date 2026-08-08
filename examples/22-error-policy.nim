import ../compiler/tuck_rt

proc tuck_unhandled*(code: uint16, site: string) =
  tuckReportUnhandled(code, site)

proc tuck_readSensor*(port: uint8): TuckResult[tuple[value: uint16]] =
  if (port > 3):
    if true:
      return terr[tuple[value: uint16]](errCode("badPort"))
  return tok((value: uint16(42)))

proc tuck_poll*(port: uint8): int =
  (let tuckDrop1 = tuck_readSensor(port); (if not tuckDrop1.ok: tuck_unhandled(tuckDrop1.err, "poll line 18")))
  return 0

