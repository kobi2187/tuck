#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"

tuck_AccumulatorMsgKind :: enum { msgAdd, msgFinish, msgShutdown }
tuck_AccumulatorMsg :: struct {
	tuckTag: tuck_AccumulatorMsgKind,
	n: int,
}
tuck_Accumulator :: struct {
	total: int,
	done: bool,
	mailbox: rt.Mailbox(tuck_AccumulatorMsg, 64),
	finished: bool,
}

tuck_AccumulatorSingleton: tuck_Accumulator

handleMsg_tuck_Accumulator :: proc(self: ^tuck_Accumulator, msg: tuck_AccumulatorMsg) {
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

tuck_AccumulatorSlot: rawptr

drain_tuck_Accumulator :: proc() -> bool {
	if tuck_AccumulatorSingleton.finished { return false }
	didWork := false
	batch, n := rt.takeBatch(&tuck_AccumulatorSingleton.mailbox)
	for i in 0 ..< n {
		handleMsg_tuck_Accumulator(&tuck_AccumulatorSingleton, batch[i])
		rt.tuckCheckWaiters()
		didWork = true
	}
	return didWork
}

sendAdd_tuck_Accumulator :: proc(self: ^tuck_Accumulator, n: int) {
	_ = rt.enqueue(&self.mailbox, tuck_AccumulatorMsg{tuckTag = .msgAdd, n = n})
	rt.tuckNotifySend(tuck_AccumulatorSlot)
}

sendFinish_tuck_Accumulator :: proc(self: ^tuck_Accumulator) {
	_ = rt.enqueue(&self.mailbox, tuck_AccumulatorMsg{tuckTag = .msgFinish})
	rt.tuckNotifySend(tuck_AccumulatorSlot)
}

sendShutdown_tuck_Accumulator :: proc(self: ^tuck_Accumulator) {
	_ = rt.enqueue(&self.mailbox, tuck_AccumulatorMsg{tuckTag = .msgShutdown})
	rt.tuckNotifySend(tuck_AccumulatorSlot)
}

tuck_ready :: proc () -> bool {
  return tuck_AccumulatorSingleton.done
}

tuck_main :: proc () -> int {
  for tuck_i in (1 ..= 10) {
      sendAdd_tuck_Accumulator(&tuck_AccumulatorSingleton, tuck_i)
  }
  sendFinish_tuck_Accumulator(&tuck_AccumulatorSingleton)
  rt.tuckWaitOn(tuck_AccumulatorSlot, tuck_ready)
  return tuck_AccumulatorSingleton.total
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	rt.tuckAsyncInit()
	tuck_AccumulatorSlot = rt.tuckStartActor(drain_tuck_Accumulator)
	mainRc := tuck_main()
	rt.tuckDrainActors()
	rt.tuckTrackCheck()
	os.exit(mainRc)
}
