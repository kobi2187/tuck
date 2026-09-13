#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"
import scheduler "./mod_scheduler"

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

drain_tuck_Counter :: proc() {
	for {
		msg: tuck_CounterMsg
		for rt.dequeue(&tuck_CounterSingleton.mailbox, &msg) {
			handleMsg_tuck_Counter(&tuck_CounterSingleton, msg)
		}
		rt.coroYield()
	}
}

sendAdd_tuck_Counter :: proc(self: ^tuck_Counter, n: int) {
	_ = rt.enqueue(&self.mailbox, tuck_CounterMsg{tuckTag = .msgAdd, n = n})
}

tuck_sumReady :: proc () -> bool {
  return (tuck_CounterSingleton.total == 55)
}

tuck_main :: proc () -> int {
  for tuck_i in (1 ..= 10) {
      sendAdd_tuck_Counter(&tuck_CounterSingleton, tuck_i)
  }
  scheduler.waitUntil(tuck_sumReady)
  return tuck_CounterSingleton.total
}

main :: proc() {
	rt.tuckAsyncInit()
	rt.tuckStartActor(drain_tuck_Counter)
	mainRc := tuck_main()
	os.exit(mainRc)
}
