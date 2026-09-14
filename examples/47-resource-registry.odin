#+feature dynamic-literals
package main

import "core:fmt"
import "core:os"
import rt "./tuckrt"

NetHandle :: rt.ResourceHandle
tuckRes_net: rt.ResourceTable = {kind = "net", cap = 10000, policy = .Lazy, onFull = .Error, sweepBatch = 100}
FileHandle :: rt.ResourceHandle
tuckRes_file: rt.ResourceTable = {kind = "file", cap = 8, policy = .Strict, onFull = .Absent, sweepBatch = 0, onFinish = rt.tuckResFlush}
UdpHandle :: rt.ResourceHandle
tuckRes_udp: rt.ResourceTable = {kind = "udp", cap = 0, policy = .Lazy, onFull = .Absent, sweepBatch = 0}
tuckResourcesShutdown :: proc() {
	rt.shutdownResources(&tuckRes_udp)
	rt.shutdownResources(&tuckRes_file)
	rt.shutdownResources(&tuckRes_net)
}

tuck_rawOpenUdp :: proc(payload: $T) -> int {
	fmt.println("TUCK PENDING: tuck_rawOpenUdp invoked (not implemented)")
	return {}
}


tuck_openUdp :: proc (port: u16) -> rt.TuckResult(UdpHandle) {
  return rt.acquireResource(&tuckRes_udp, i64(tuck_rawOpenUdp(port)), "47-resource-registry:46")
}

tuck_withScratch :: proc (n: int) -> int {
  tuck_scratch := n
  defer {
    tuck_scratch = 0
  }
  return (tuck_scratch + 1)
}

tuck_serve :: proc (port: u16) -> int {
  tuck_sock := tuck_openUdp(port)
  if (tuck_sock.status == .Ok) {
      defer {
        rt.finishResource(&tuckRes_udp, tuck_sock.value)
      }
      return 1
  }
  return 0
}

tuck_main :: proc () -> int {
  return tuck_withScratch(16)
}

main :: proc() {
	mainRc := tuck_main()
	tuckResourcesShutdown()
	os.exit(mainRc)
}
