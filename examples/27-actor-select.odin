#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"

tuck_type_AccumulatorMsgKind :: enum { msgAdd, msgFinish, msgShutdown }
tuck_type_AccumulatorMsg :: struct {
	tuckTag: tuck_type_AccumulatorMsgKind,
	n: int,
}
tuck_type_Accumulator :: struct {
	total: int,
	done: bool,
	mailbox: rt.Mailbox(tuck_type_AccumulatorMsg, 64),
	finished: bool,
}

tuck_type_AccumulatorSingleton: tuck_type_Accumulator

handleMsg_tuck_type_Accumulator :: proc(self: ^tuck_type_Accumulator, msg: tuck_type_AccumulatorMsg) {
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

tuck_type_AccumulatorSlot: rawptr

drain_tuck_type_Accumulator :: proc() -> bool {
	if tuck_type_AccumulatorSingleton.finished { return false }
	didWork := false
	batch, n := rt.takeBatch(&tuck_type_AccumulatorSingleton.mailbox)
	for i in 0 ..< n {
		handleMsg_tuck_type_Accumulator(&tuck_type_AccumulatorSingleton, batch[i])
		rt.tuckCheckWaiters()
		didWork = true
	}
	return didWork
}

sendAdd_tuck_type_Accumulator :: proc(self: ^tuck_type_Accumulator, n: int) {
	_ = rt.enqueue(&self.mailbox, tuck_type_AccumulatorMsg{tuckTag = .msgAdd, n = n})
	rt.tuckNotifySend(tuck_type_AccumulatorSlot)
}

sendFinish_tuck_type_Accumulator :: proc(self: ^tuck_type_Accumulator) {
	_ = rt.enqueue(&self.mailbox, tuck_type_AccumulatorMsg{tuckTag = .msgFinish})
	rt.tuckNotifySend(tuck_type_AccumulatorSlot)
}

sendShutdown_tuck_type_Accumulator :: proc(self: ^tuck_type_Accumulator) {
	_ = rt.enqueue(&self.mailbox, tuck_type_AccumulatorMsg{tuckTag = .msgShutdown})
	rt.tuckNotifySend(tuck_type_AccumulatorSlot)
}

tuck_fn_ready :: proc () -> bool {
  return tuck_type_AccumulatorSingleton.done
}

tuck_fn_main :: proc () -> int {
  for tuck_i in (1 ..= 10) {
      sendAdd_tuck_type_Accumulator(&tuck_type_AccumulatorSingleton, tuck_i)
  }
  sendFinish_tuck_type_Accumulator(&tuck_type_AccumulatorSingleton)
  rt.tuckWaitOn(tuck_type_AccumulatorSlot, tuck_fn_ready)
  return tuck_type_AccumulatorSingleton.total
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuck_type_AccumulatorSingleton.total = 0
	tuck_type_AccumulatorSingleton.done = false
	rt.tuckAsyncInit()
	tuck_type_AccumulatorSlot = rt.tuckStartActor(drain_tuck_type_Accumulator)
	mainRc := tuck_fn_main()
	rt.tuckDrainActors()
	rt.tuckTrackCheck()
	os.exit(mainRc)
}
