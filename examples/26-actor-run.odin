#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"

tuck_CounterMsgKind :: enum { msgAdd }
tuck_CounterMsg :: struct {
	tuckTag: tuck_CounterMsgKind,
	n: int,
}
tuck_Counter :: struct {
	total: int,
	mailbox: rt.Mailbox(tuck_CounterMsg, 128),
}

tuck_CounterSingleton: tuck_Counter

handleMsg_tuck_Counter :: proc(self: ^tuck_Counter, msg: tuck_CounterMsg) {
	switch msg.tuckTag {
	case .msgAdd:
		n := msg.n
    self.total = (self.total + n)
	}
}

tuck_CounterSlot: rawptr

drain_tuck_Counter :: proc() -> bool {
	didWork := false
	batch, n := rt.takeBatch(&tuck_CounterSingleton.mailbox)
	for i in 0 ..< n {
		handleMsg_tuck_Counter(&tuck_CounterSingleton, batch[i])
		rt.tuckCheckWaiters()
		didWork = true
	}
	return didWork
}

sendAdd_tuck_Counter :: proc(self: ^tuck_Counter, n: int) {
	_ = rt.enqueue(&self.mailbox, tuck_CounterMsg{tuckTag = .msgAdd, n = n})
	rt.tuckNotifySend(tuck_CounterSlot)
}

tuck_sumReady :: proc () -> bool {
  return (tuck_CounterSingleton.total == 55)
}

tuck_main :: proc () -> int {
  for tuck_i in (1 ..= 10) {
      sendAdd_tuck_Counter(&tuck_CounterSingleton, tuck_i)
  }
  rt.tuckWaitOn(tuck_CounterSlot, tuck_sumReady)
  return tuck_CounterSingleton.total
}

main :: proc() {
	rt.tuckAsyncInit()
	tuck_CounterSlot = rt.tuckStartActor(drain_tuck_Counter)
	mainRc := tuck_main()
	rt.tuckDrainActors()
	os.exit(mainRc)
}
