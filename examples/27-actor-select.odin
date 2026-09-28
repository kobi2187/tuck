#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"

tuckˑactorˑAccumulatorMsgKind :: enum { msgAdd, msgFinish, msgShutdown }
tuckˑactorˑAccumulatorMsg :: struct {
	tuckTag: tuckˑactorˑAccumulatorMsgKind,
	n: int,
}
tuckˑactorˑAccumulator :: struct {
	total: int,
	done: bool,
	mailbox: rt.Mailbox(tuckˑactorˑAccumulatorMsg, 64),
	finished: bool,
}

tuckˑactorˑAccumulatorSingleton: tuckˑactorˑAccumulator

handleMsg_tuckˑactorˑAccumulator :: proc(self: ^tuckˑactorˑAccumulator, msg: tuckˑactorˑAccumulatorMsg) {
	switch msg.tuckTag {
	case .msgAdd:
		n := msg.n
self.total = (self.total + n)
	case .msgFinish:
self.done = true
	case .msgShutdown:
self.total = self.total
		self.finished = true
	}
}

tuckˑactorˑAccumulatorSlot: rawptr

drain_tuckˑactorˑAccumulator :: proc() -> bool {
	if tuckˑactorˑAccumulatorSingleton.finished { return false }
	didWork := false
	batch, n := rt.takeBatch(&tuckˑactorˑAccumulatorSingleton.mailbox)
	for i in 0 ..< n {
		handleMsg_tuckˑactorˑAccumulator(&tuckˑactorˑAccumulatorSingleton, batch[i])
		rt.tuckCheckWaiters()
		didWork = true
	}
	return didWork
}

sendAdd_tuckˑactorˑAccumulator :: proc(self: ^tuckˑactorˑAccumulator, n: int) {
	_ = rt.enqueue(&self.mailbox, tuckˑactorˑAccumulatorMsg{tuckTag = .msgAdd, n = n})
	rt.tuckNotifySend(tuckˑactorˑAccumulatorSlot)
}

sendFinish_tuckˑactorˑAccumulator :: proc(self: ^tuckˑactorˑAccumulator) {
	_ = rt.enqueue(&self.mailbox, tuckˑactorˑAccumulatorMsg{tuckTag = .msgFinish})
	rt.tuckNotifySend(tuckˑactorˑAccumulatorSlot)
}

sendShutdown_tuckˑactorˑAccumulator :: proc(self: ^tuckˑactorˑAccumulator) {
	_ = rt.enqueue(&self.mailbox, tuckˑactorˑAccumulatorMsg{tuckTag = .msgShutdown})
	rt.tuckNotifySend(tuckˑactorˑAccumulatorSlot)
}

tuckˑfnˑready :: proc () -> bool {
  return tuckˑactorˑAccumulatorSingleton.done
}

tuckˑfnˑmain :: proc () -> int {
  for tuckˑvˑi in (1 ..= 10) {
      sendAdd_tuckˑactorˑAccumulator(&tuckˑactorˑAccumulatorSingleton, tuckˑvˑi)
  }
  sendFinish_tuckˑactorˑAccumulator(&tuckˑactorˑAccumulatorSingleton)
  rt.tuckWaitOn(tuckˑactorˑAccumulatorSlot, tuckˑfnˑready)
  return tuckˑactorˑAccumulatorSingleton.total
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuckˑactorˑAccumulatorSingleton.total = 0
	tuckˑactorˑAccumulatorSingleton.done = false
	rt.tuckAsyncInit()
	tuckˑactorˑAccumulatorSlot = rt.tuckStartActor(drain_tuckˑactorˑAccumulator)
	mainRc := tuckˑfnˑmain()
	rt.tuckDrainActors()
	rt.tuckTrackCheck()
	os.exit(mainRc)
}
