#+feature dynamic-literals
package main

import "core:fmt"
import "core:os"
import rt "./tuckrt"

tuck_type_NetState :: enum { Connecting, Ready, Closed }
canTransition_tuck_type_NetState :: proc(frm: tuck_type_NetState, to: tuck_type_NetState) -> bool {
	switch frm {
	case .Connecting: return to == .Ready || to == .Closed
	case .Ready: return to == .Closed
	case .Closed: return false
	}
	return false
}
transitionTo_tuck_type_NetState :: proc(self: ^tuck_type_NetState, target: tuck_type_NetState) {
	assert(canTransition_tuck_type_NetState(self^, target), "Invalid transition")
	self^ = target
}

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

tuck_fn_rawOpenUdp :: proc(payload: $T) -> int {
	fmt.println("TUCK PENDING: tuck_fn_rawOpenUdp invoked (not implemented)")
	return {}
}


tuck_fn_openUdp :: proc (port: u16) -> rt.TuckResult(UdpHandle) {
  return rt.acquireResource(&tuckRes_udp, i64(tuck_fn_rawOpenUdp(port)), "47-resource-registry:73")
}

tuck_fn_withScratch :: proc (n: int) -> int {
  tuck_scratch := n
  defer {
    tuck_scratch = 0
  }
  return (tuck_scratch + 1)
}

tuck_fn_serve :: proc (port: u16) -> int {
  tuck_sock := tuck_fn_openUdp(port)
  if (tuck_sock.status == .Ok) {
      defer {
        rt.finishResource(&tuckRes_udp, tuck_sock.value)
      }
      return 1
  }
  return 0
}

tuck_fn_main :: proc () -> int {
  return tuck_fn_withScratch(16)
}

main :: proc() {
	mainRc := tuck_fn_main()
	tuckResourcesShutdown()
	os.exit(mainRc)
}
