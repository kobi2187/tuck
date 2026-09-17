#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"
import scheduler "./mod_scheduler"

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

drain_tuck_Accumulator :: proc() {
	for {
		if tuck_AccumulatorSingleton.finished { return }
		msg: tuck_AccumulatorMsg
		didWork := false
		for rt.dequeue(&tuck_AccumulatorSingleton.mailbox, &msg) {
			handleMsg_tuck_Accumulator(&tuck_AccumulatorSingleton, msg)
			didWork = true
		}
		if didWork { rt.coroYield() } else { rt.tuckParkActor() }
	}
}

sendAdd_tuck_Accumulator :: proc(self: ^tuck_Accumulator, n: int) {
	_ = rt.enqueue(&self.mailbox, tuck_AccumulatorMsg{tuckTag = .msgAdd, n = n})
}

sendFinish_tuck_Accumulator :: proc(self: ^tuck_Accumulator) {
	_ = rt.enqueue(&self.mailbox, tuck_AccumulatorMsg{tuckTag = .msgFinish})
}

sendShutdown_tuck_Accumulator :: proc(self: ^tuck_Accumulator) {
	_ = rt.enqueue(&self.mailbox, tuck_AccumulatorMsg{tuckTag = .msgShutdown})
}

tuck_ready :: proc () -> bool {
  return tuck_AccumulatorSingleton.done
}

tuck_main :: proc () -> int {
  for tuck_i in (1 ..= 10) {
      sendAdd_tuck_Accumulator(&tuck_AccumulatorSingleton, tuck_i)
  }
  sendFinish_tuck_Accumulator(&tuck_AccumulatorSingleton)
  scheduler.waitUntil(tuck_ready)
  return tuck_AccumulatorSingleton.total
}

main :: proc() {
	rt.tuckAsyncInit()
	rt.tuckStartActor(drain_tuck_Accumulator)
	mainRc := tuck_main()
	os.exit(mainRc)
}
