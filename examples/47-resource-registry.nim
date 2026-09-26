{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuckˑfnˑopenUdp*(port: uint16): TuckResult[UdpHandle]
proc tuckˑfnˑwithScratch*(n: int): int
proc tuckˑfnˑserve*(port: uint16): int
proc tuckˑfnˑmain*(): int

type tuckˑtypeˑNetState* = enum Connecting, Ready, Closed
proc canTransition*(frm, to: tuckˑtypeˑNetState): bool =
  case frm
  of Connecting: to in {Ready, Closed}
  of Ready: to in {Closed}
  of Closed: false
proc transitionTo*(self: var tuckˑtypeˑNetState, target: tuckˑtypeˑNetState) =
  if not canTransition(self, target):
    raise newException(ValueError, "Invalid transition " & $self & " -> " & $target)
  self = target

type NetHandle* = ResourceHandle
var tuckRes_net* = ResourceTable(kind: "net", cap: 10000, policy: rtLazy, onFull: rtoError, sweepBatch: 100)
type FileHandle* = ResourceHandle
var tuckRes_file* = ResourceTable(kind: "file", cap: 8, policy: rtStrict, onFull: rtoAbsent, sweepBatch: 0, onFinish: tuckResFlush)
type UdpHandle* = ResourceHandle
var tuckRes_udp* = ResourceTable(kind: "udp", cap: 0, policy: rtLazy, onFull: rtoAbsent, sweepBatch: 0)
proc tuckResourcesShutdown*() =
  shutdownResources(tuckRes_udp)
  shutdownResources(tuckRes_file)
  shutdownResources(tuckRes_net)

proc tuckˑfnˑrawOpenUdp*[T](payload: T): int =
  stderr.writeLine("TUCK PENDING: rawOpenUdp invoked (not implemented)")


proc tuckˑfnˑopenUdp*(port: uint16): TuckResult[UdpHandle] =
  return acquire(tuckRes_udp, int64(tuckˑfnˑrawOpenUdp(port)), "47-resource-registry:73")

proc tuckˑfnˑwithScratch*(n: int): int =
  var tuckˑvˑscratch = n
  defer:
    tuckˑvˑscratch = 0
  return (tuckˑvˑscratch + 1)

proc tuckˑfnˑserve*(port: uint16): int =
  var tuckˑvˑsock = tuckˑfnˑopenUdp(port)
  if tuckˑvˑsock.ok:
    if true:
      defer:
        finish(tuckRes_udp, tuckˑvˑsock.value)
      return 1
  return 0

proc tuckˑfnˑmain*(): int =
  return tuckˑfnˑwithScratch(16)

