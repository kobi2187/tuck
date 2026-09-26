#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"

tuck_type_CounterMsgKind :: enum { msgAdd }
tuck_type_CounterMsg :: struct {
	tuckTag: tuck_type_CounterMsgKind,
	n: int,
}
tuck_type_Counter :: struct {
	total: int,
	mailbox: rt.Mailbox(tuck_type_CounterMsg, 128),
}

tuck_type_CounterSingleton: tuck_type_Counter

handleMsg_tuck_type_Counter :: proc(self: ^tuck_type_Counter, msg: tuck_type_CounterMsg) {
	switch msg.tuckTag {
	case .msgAdd:
		n := msg.n
    self.total = (self.total + n)
	}
}

tuck_type_CounterSlot: rawptr

drain_tuck_type_Counter :: proc() -> bool {
	didWork := false
	batch, n := rt.takeBatch(&tuck_type_CounterSingleton.mailbox)
	for i in 0 ..< n {
		handleMsg_tuck_type_Counter(&tuck_type_CounterSingleton, batch[i])
		rt.tuckCheckWaiters()
		didWork = true
	}
	return didWork
}

sendAdd_tuck_type_Counter :: proc(self: ^tuck_type_Counter, n: int) {
	_ = rt.enqueue(&self.mailbox, tuck_type_CounterMsg{tuckTag = .msgAdd, n = n})
	rt.tuckNotifySend(tuck_type_CounterSlot)
}

tuck_fn_sumReady :: proc () -> bool {
  return (tuck_type_CounterSingleton.total == 55)
}

tuck_fn_main :: proc () -> int {
  for tuck_i in (1 ..= 10) {
      sendAdd_tuck_type_Counter(&tuck_type_CounterSingleton, tuck_i)
  }
  rt.tuckWaitOn(tuck_type_CounterSlot, tuck_fn_sumReady)
  return tuck_type_CounterSingleton.total
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuck_type_CounterSingleton.total = 0
	rt.tuckAsyncInit()
	tuck_type_CounterSlot = rt.tuckStartActor(drain_tuck_type_Counter)
	mainRc := tuck_fn_main()
	rt.tuckDrainActors()
	rt.tuckTrackCheck()
	os.exit(mainRc)
}
