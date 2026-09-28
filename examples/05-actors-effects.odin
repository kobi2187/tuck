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

tuckˑtypeˑFeed :: struct {
	title: string,
	episodeCount: int,
}

tuckˑactorˑCounterMsgKind :: enum { msgIncrement, msgReset }
tuckˑactorˑCounterMsg :: struct {
	tuckTag: tuckˑactorˑCounterMsgKind,
	n: int,
}
tuckˑactorˑCounter :: struct {
	count: int,
	mailbox: rt.Mailbox(tuckˑactorˑCounterMsg, 8),
}

tuckˑactorˑCounterSingleton: tuckˑactorˑCounter

handleMsg_tuckˑactorˑCounter :: proc(self: ^tuckˑactorˑCounter, msg: tuckˑactorˑCounterMsg) {
	switch msg.tuckTag {
	case .msgIncrement:
		n := msg.n
    self.count = (self.count + n)
	case .msgReset:
    self.count = 0
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

sendIncrement_tuckˑactorˑCounter :: proc(self: ^tuckˑactorˑCounter, n: int) {
	_ = rt.enqueue(&self.mailbox, tuckˑactorˑCounterMsg{tuckTag = .msgIncrement, n = n})
	rt.tuckNotifySend(tuckˑactorˑCounterSlot)
}

sendReset_tuckˑactorˑCounter :: proc(self: ^tuckˑactorˑCounter) {
	_ = rt.enqueue(&self.mailbox, tuckˑactorˑCounterMsg{tuckTag = .msgReset})
	rt.tuckNotifySend(tuckˑactorˑCounterSlot)
}

tuckˑfnˑreadSensor :: proc(payload: $T) -> rt.TuckResult(TRec_value(u16)) {
	fmt.println("TUCK PENDING: readSensor invoked (not implemented)")
	return {}
}

tuckˑobjectˑPodcastApp :: struct {
}

fetchFeed :: proc(payload: $T) -> rt.TuckResult(TRec_feed(tuckˑtypeˑFeed)) {
	fmt.println("TUCK PENDING: fetchFeed invoked (not implemented)")
	return {}
}



main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuckˑactorˑCounterSingleton.count = 0
	rt.tuckAsyncInit()
	tuckˑactorˑCounterSlot = rt.tuckStartActor(drain_tuckˑactorˑCounter)
	rt.tuckDrainActors()
	rt.tuckTrackCheck()
}
