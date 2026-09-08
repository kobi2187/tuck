#+feature dynamic-literals
package main

import "core:fmt"
import rt "./tuckrt"

TRec_value_638E :: struct {
	value: u16,
}

TRec_feed_A1A6 :: struct {
	feed: tuck_Feed,
}

tuck_Feed :: struct {
	title: string,
	episodeCount: int,
}

tuck_CounterMsgKind :: enum { msgIncrement, msgReset }
tuck_CounterMsg :: struct {
	kind: tuck_CounterMsgKind,
	n: int,
}
tuck_Counter :: struct {
	count: int,
	mailbox: rt.Mailbox(tuck_CounterMsg, 8),
}

tuck_CounterSingleton: tuck_Counter

handleMsg_tuck_Counter :: proc(self: ^tuck_Counter, msg: tuck_CounterMsg) {
	switch msg.kind {
	case .msgIncrement:
		n := msg.n
    self.count = (self.count + n)
	case .msgReset:
    self.count = 0
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

sendIncrement_tuck_Counter :: proc(self: ^tuck_Counter, n: int) {
	_ = rt.enqueue(&self.mailbox, tuck_CounterMsg{kind = .msgIncrement, n = n})
}

sendReset_tuck_Counter :: proc(self: ^tuck_Counter) {
	_ = rt.enqueue(&self.mailbox, tuck_CounterMsg{kind = .msgReset})
}

tuck_readSensor :: proc (port: u8) -> rt.TuckResult(TRec_value_638E) {

  return {}
}

tuck_PodcastApp :: struct {
}

fetchFeed :: proc(payload: $T) -> rt.TuckResult(TRec_feed_A1A6) {
	fmt.println("TUCK PENDING: fetchFeed invoked (not implemented)")
	return {}
}



main :: proc() {
	rt.tuckAsyncInit()
	rt.tuckStartActor(drain_tuck_Counter)
}
