#+feature dynamic-literals
package main

import "core:fmt"
import rt "./tuckrt"

TRec_value :: struct ($T_value: typeid) {
	value: T_value,
}

TRec_feed :: struct ($T_feed: typeid) {
	feed: T_feed,
}

tuck_type_Feed :: struct {
	title: string,
	episodeCount: int,
}

tuck_type_CounterMsgKind :: enum { msgIncrement, msgReset }
tuck_type_CounterMsg :: struct {
	tuckTag: tuck_type_CounterMsgKind,
	n: int,
}
tuck_type_Counter :: struct {
	count: int,
	mailbox: rt.Mailbox(tuck_type_CounterMsg, 8),
}

tuck_type_CounterSingleton: tuck_type_Counter

handleMsg_tuck_type_Counter :: proc(self: ^tuck_type_Counter, msg: tuck_type_CounterMsg) {
	switch msg.tuckTag {
	case .msgIncrement:
		n := msg.n
    self.count = (self.count + n)
	case .msgReset:
    self.count = 0
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

sendIncrement_tuck_type_Counter :: proc(self: ^tuck_type_Counter, n: int) {
	_ = rt.enqueue(&self.mailbox, tuck_type_CounterMsg{tuckTag = .msgIncrement, n = n})
	rt.tuckNotifySend(tuck_type_CounterSlot)
}

sendReset_tuck_type_Counter :: proc(self: ^tuck_type_Counter) {
	_ = rt.enqueue(&self.mailbox, tuck_type_CounterMsg{tuckTag = .msgReset})
	rt.tuckNotifySend(tuck_type_CounterSlot)
}

tuck_fn_readSensor :: proc(payload: $T) -> rt.TuckResult(TRec_value(u16)) {
	fmt.println("TUCK PENDING: tuck_fn_readSensor invoked (not implemented)")
	return {}
}

tuck_type_PodcastApp :: struct {
}

fetchFeed :: proc(payload: $T) -> rt.TuckResult(TRec_feed(tuck_type_Feed)) {
	fmt.println("TUCK PENDING: fetchFeed invoked (not implemented)")
	return {}
}



main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuck_type_CounterSingleton.count = 0
	rt.tuckAsyncInit()
	tuck_type_CounterSlot = rt.tuckStartActor(drain_tuck_type_Counter)
	rt.tuckDrainActors()
	rt.tuckTrackCheck()
}
