#+feature dynamic-literals
package main

import "core:fmt"
import "core:os"
import rt "./tuckrt"

tuckˑtypeˑNetState :: enum { Connecting, Ready, Closed }
canTransition_tuckˑtypeˑNetState :: proc(frm: tuckˑtypeˑNetState, to: tuckˑtypeˑNetState) -> bool {
	switch frm {
	case .Connecting: return to == .Ready || to == .Closed
	case .Ready: return to == .Closed
	case .Closed: return false
	}
	return false
}
transitionTo_tuckˑtypeˑNetState :: proc(self: ^tuckˑtypeˑNetState, target: tuckˑtypeˑNetState) {
	assert(canTransition_tuckˑtypeˑNetState(self^, target), "Invalid transition")
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

tuckˑfnˑrawOpenUdp :: proc(payload: $T) -> int {
	fmt.println("TUCK PENDING: rawOpenUdp invoked (not implemented)")
	return {}
}


tuckˑfnˑopenUdp :: proc (port: u16) -> rt.TuckResult(UdpHandle) {
  return rt.acquireResource(&tuckRes_udp, i64(tuckˑfnˑrawOpenUdp(port)), "47-resource-registry:73")
}

tuckˑfnˑwithScratch :: proc (n: int) -> int {
  tuckˑvˑscratch := n
  defer {
    tuckˑvˑscratch = 0
  }
  return (tuckˑvˑscratch + 1)
}

tuckˑfnˑserve :: proc (port: u16) -> int {
  tuckˑvˑsock := tuckˑfnˑopenUdp(port)
  if (tuckˑvˑsock.status == .Ok) {
      defer {
        rt.finishResource(&tuckRes_udp, tuckˑvˑsock.value)
      }
      return 1
  }
  return 0
}

tuckˑfnˑmain :: proc () -> int {
  return tuckˑfnˑwithScratch(16)
}

main :: proc() {
	mainRc := tuckˑfnˑmain()
	tuckResourcesShutdown()
	os.exit(mainRc)
}
