#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"

tuckˑactorˑCounterMsgKind :: enum { msgAdd }
tuckˑactorˑCounterMsg :: struct {
	tuckTag: tuckˑactorˑCounterMsgKind,
	n: int,
}
tuckˑactorˑCounter :: struct {
	total: int,
	mailbox: rt.Mailbox(tuckˑactorˑCounterMsg, 128),
}

tuckˑactorˑCounterSingleton: tuckˑactorˑCounter

handleMsg_tuckˑactorˑCounter :: proc(self: ^tuckˑactorˑCounter, msg: tuckˑactorˑCounterMsg) {
	switch msg.tuckTag {
	case .msgAdd:
		n := msg.n
    self.total = (self.total + n)
	}
}

tuckˑactorˑCounterSlot: rawptr

drain_tuckˑactorˑCounter :: proc() -> bool {
	didWork := false
	batch, n := rt.takeBatch(&tuckˑactorˑCounterSingleton.mailbox)
	for i in 0 ..< n {
		handleMsg_tuckˑactorˑCounter(&tuckˑactorˑCounterSingleton, batch[i])
		rt.tuckCheckWaiters()
		didWork = true
	}
	return didWork
}

sendAdd_tuckˑactorˑCounter :: proc(self: ^tuckˑactorˑCounter, n: int) {
	_ = rt.enqueue(&self.mailbox, tuckˑactorˑCounterMsg{tuckTag = .msgAdd, n = n})
	rt.tuckNotifySend(tuckˑactorˑCounterSlot)
}

tuckˑfnˑsumReady :: proc () -> bool {
  return (tuckˑactorˑCounterSingleton.total == 55)
}

tuckˑfnˑmain :: proc () -> int {
  for tuckˑvˑi in (1 ..= 10) {
      sendAdd_tuckˑactorˑCounter(&tuckˑactorˑCounterSingleton, tuckˑvˑi)
  }
  rt.tuckWaitOn(tuckˑactorˑCounterSlot, tuckˑfnˑsumReady)
  return tuckˑactorˑCounterSingleton.total
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuckˑactorˑCounterSingleton.total = 0
	rt.tuckAsyncInit()
	tuckˑactorˑCounterSlot = rt.tuckStartActor(drain_tuckˑactorˑCounter)
	mainRc := tuckˑfnˑmain()
	rt.tuckDrainActors()
	rt.tuckTrackCheck()
	os.exit(mainRc)
}
