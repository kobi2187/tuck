#+feature dynamic-literals
package main

import rt "./tuckrt"

tuck_type_TrafficLightStateKind :: enum { Red, Yellow, Green }

tuck_type_TrafficLightMsgKind :: enum { msgNext }
tuck_type_TrafficLightMsg :: struct {
	tuckTag: tuck_type_TrafficLightMsgKind,
}
tuck_type_TrafficLight :: struct {
	state: tuck_type_TrafficLightStateKind,
	mailbox: rt.Mailbox(tuck_type_TrafficLightMsg, 4),
}

tuck_type_TrafficLightSingleton: tuck_type_TrafficLight

handleMsg_tuck_type_TrafficLight :: proc(self: ^tuck_type_TrafficLight, msg: tuck_type_TrafficLightMsg) {
	switch msg.tuckTag {
	case .msgNext:
    self.state = ((self.state == .Red) ? .Green : ((self.state == .Green) ? .Yellow : .Red))
	}
}

tuck_type_TrafficLightSlot: rawptr

drain_tuck_type_TrafficLight :: proc() -> bool {
	didWork := false
	batch, n := rt.takeBatch(&tuck_type_TrafficLightSingleton.mailbox)
	for i in 0 ..< n {
		handleMsg_tuck_type_TrafficLight(&tuck_type_TrafficLightSingleton, batch[i])
		rt.tuckCheckWaiters()
		didWork = true
	}
	return didWork
}

sendNext_tuck_type_TrafficLight :: proc(self: ^tuck_type_TrafficLight) {
	_ = rt.enqueue(&self.mailbox, tuck_type_TrafficLightMsg{tuckTag = .msgNext})
	rt.tuckNotifySend(tuck_type_TrafficLightSlot)
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuck_type_TrafficLightSingleton.state = .Red
	rt.tuckAsyncInit()
	tuck_type_TrafficLightSlot = rt.tuckStartActor(drain_tuck_type_TrafficLight)
	rt.tuckDrainActors()
	rt.tuckTrackCheck()
}
