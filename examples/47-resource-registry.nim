{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuck_openUdp*(port: uint16): TuckResult[UdpHandle]
proc tuck_withScratch*(n: int): int
proc tuck_serve*(port: uint16): int
proc tuck_main*(): int

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

proc tuck_rawOpenUdp*[T](payload: T): int =
  stderr.writeLine("TUCK PENDING: tuck_rawOpenUdp invoked (not implemented)")


proc tuck_openUdp*(port: uint16): TuckResult[UdpHandle] =
  return acquire(tuckRes_udp, int64(tuck_rawOpenUdp(port)), "47-resource-registry:69")

proc tuck_withScratch*(n: int): int =
  var tuck_scratch = n
  defer:
    tuck_scratch = 0
  return (tuck_scratch + 1)

proc tuck_serve*(port: uint16): int =
  var tuck_sock = tuck_openUdp(port)
  if tuck_sock.ok:
    if true:
      defer:
        finish(tuckRes_udp, tuck_sock.value)
      return 1
  return 0

proc tuck_main*(): int =
  return tuck_withScratch(16)

