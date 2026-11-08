# Nim impl module for std.chrono's time zones — twins: zone_shim.odin and
# zone_shim.d. The rules are the operating system's tz database
# (/usr/share/zoneinfo) read through libc: the offset in force in a zone at an
# instant, whether it is daylight time, and its abbreviation. NOT thread-safe:
# libc keeps the zone in the TZ variable, so zone lookups run one at a time.
import std/[os, posix, strutils]

type Tm {.importc: "struct tm", header: "<time.h>".} = object
  tm_gmtoff: clong
  tm_isdst: cint
  tm_zone: cstring

proc localtime_r(t: ptr Time, tm: ptr Tm): pointer {.importc, header: "<time.h>", cdecl.}
proc tzset() {.importc, header: "<time.h>", cdecl.}

const NoZone = 999999

proc zoneOk(zone: string): bool =
  if zone.len == 0 or zone[0] == '/' or zone[0] == ':' or ".." in zone: return false
  if zone == "UTC": return true
  fileExists("/usr/share/zoneinfo/" & zone)

proc here(zone: string, t: int, tm: var Tm): bool =
  if not zoneOk(zone): return false
  putEnv("TZ", zone)
  tzset()
  var tt = Time(t)
  localtime_r(addr tt, addr tm) != nil

proc tzOffsetAt*(zone: string, epochSec: int): int =
  ## Seconds east of UTC in force then, or 999999 for an unknown zone.
  var tm: Tm
  if not here(zone, epochSec, tm): return NoZone
  int tm.tm_gmtoff

proc tzIsDst*(zone: string, epochSec: int): int =
  var tm: Tm
  if not here(zone, epochSec, tm): return 0
  if tm.tm_isdst > 0: 1 else: 0

proc tzAbbrev*(zone: string, epochSec: int): seq[uint8] =
  var tm: Tm
  if not here(zone, epochSec, tm) or tm.tm_zone == nil: return @[]
  for c in $tm.tm_zone: result.add uint8(c)
