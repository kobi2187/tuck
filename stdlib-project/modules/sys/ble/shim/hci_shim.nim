# Nim impl module for sys.ble's Linux HCI scanner — twins: hci_shim.odin and
# hci_shim.d. A raw HCI socket stays in this table; Tuck holds a HANDLE and
# reads whole HCI event packets as bytes. LE scanning is switched on at open and
# off at close. Needs an adapter and CAP_NET_RAW (or root).
import std/posix
{.passL: "-lbluetooth".}

proc hci_open_dev(dev: cint): cint {.importc, cdecl.}
proc hci_le_set_scan_parameters(dd: cint, kind: uint8, interval, window: uint16,
                                own: uint8, filter: uint8, to: cint): cint {.importc, cdecl.}
proc hci_le_set_scan_enable(dd: cint, enable: uint8, filterDup: uint8, to: cint): cint {.importc, cdecl.}
proc hci_close_dev(dd: cint): cint {.importc, cdecl.}

var gSocks: seq[cint]

proc valid(h: int): bool = h >= 0 and h < gSocks.len and gSocks[h] >= 0

proc hciOpen*(adapter: int): int =
  ## A scanner handle >= 0; -1 no such adapter; -2 not permitted / refused.
  let dd = hci_open_dev(cint adapter)
  if dd < 0:
    return (if errno == EPERM or errno == EACCES: -2 else: -1)
  if hci_le_set_scan_parameters(dd, 0, 0x0010, 0x0010, 0, 0, 1000) < 0 or
     hci_le_set_scan_enable(dd, 1, 0, 1000) < 0:
    discard hci_close_dev(dd)
    return -2
  # deliver only HCI events, and of those only LE Meta (0x3E)
  var filter: array[16, uint8]
  filter[0] = uint8(1 shl 4)                 # type_mask: HCI_EVENT_PKT
  filter[8 + 3] = uint8(1 shl (62 - 32 - 24)) # event_mask[1] bit 30
  discard setsockopt(SocketHandle dd, 0, 2, addr filter[0], SockLen 14)
  gSocks.add dd
  gSocks.len - 1

proc hciRead*(h, timeoutMs: int): seq[uint8] =
  ## One packet, or empty after the timeout.
  if not valid(h): return @[]
  var p = TPollfd(fd: gSocks[h], events: POLLIN)
  if poll(addr p, 1, cint timeoutMs) <= 0: return @[]
  var buf = newSeq[uint8](260)
  let n = read(gSocks[h], addr buf[0], 260)
  if n <= 0: return @[]
  buf.setLen n
  buf

proc hciClose*(h: int) =
  if not valid(h): return
  discard hci_le_set_scan_enable(gSocks[h], 0, 0, 1000)
  discard hci_close_dev(gSocks[h])
  gSocks[h] = -1
