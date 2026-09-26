#+feature dynamic-literals
package main

import rt "./tuckrt"

tuckˑactorˑTrafficLightStateKind :: enum { Red, Yellow, Green }

tuckˑactorˑTrafficLightMsgKind :: enum { msgNext }
tuckˑactorˑTrafficLightMsg :: struct {
	tuckTag: tuckˑactorˑTrafficLightMsgKind,
}
tuckˑactorˑTrafficLight :: struct {
	state: tuckˑactorˑTrafficLightStateKind,
	mailbox: rt.Mailbox(tuckˑactorˑTrafficLightMsg, 4),
}

tuckˑactorˑTrafficLightSingleton: tuckˑactorˑTrafficLight

handleMsg_tuckˑactorˑTrafficLight :: proc(self: ^tuckˑactorˑTrafficLight, msg: tuckˑactorˑTrafficLightMsg) {
	switch msg.tuckTag {
	case .msgNext:
    self.state = ((self.state == .Red) ? .Green : ((self.state == .Green) ? .Yellow : .Red))
	}
}

tuckˑactorˑTrafficLightSlot: rawptr

drain_tuckˑactorˑTrafficLight :: proc() -> bool {
	didWork := false
	batch, n := rt.takeBatch(&tuckˑactorˑTrafficLightSingleton.mailbox)
	for i in 0 ..< n {
		handleMsg_tuckˑactorˑTrafficLight(&tuckˑactorˑTrafficLightSingleton, batch[i])
		rt.tuckCheckWaiters()
		didWork = true
	}
	return didWork
}

sendNext_tuckˑactorˑTrafficLight :: proc(self: ^tuckˑactorˑTrafficLight) {
	_ = rt.enqueue(&self.mailbox, tuckˑactorˑTrafficLightMsg{tuckTag = .msgNext})
	rt.tuckNotifySend(tuckˑactorˑTrafficLightSlot)
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuckˑactorˑTrafficLightSingleton.state = .Red
	rt.tuckAsyncInit()
	tuckˑactorˑTrafficLightSlot = rt.tuckStartActor(drain_tuckˑactorˑTrafficLight)
	rt.tuckDrainActors()
	rt.tuckTrackCheck()
}
