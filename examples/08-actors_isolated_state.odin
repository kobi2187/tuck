#+feature dynamic-literals
package main

import rt "./tuckrt"

tuck_TrafficLightStateKind :: enum { Red, Yellow, Green }

tuck_TrafficLightMsgKind :: enum { msgNext }
tuck_TrafficLightMsg :: struct {
	tuckTag: tuck_TrafficLightMsgKind,
}
tuck_TrafficLight :: struct {
	state: tuck_TrafficLightStateKind,
	mailbox: rt.Mailbox(tuck_TrafficLightMsg, 4),
}

tuck_TrafficLightSingleton: tuck_TrafficLight

handleMsg_tuck_TrafficLight :: proc(self: ^tuck_TrafficLight, msg: tuck_TrafficLightMsg) {
	switch msg.tuckTag {
	case .msgNext:
    self.state = ((self.state == .Red) ? .Green : ((self.state == .Green) ? .Yellow : .Red))
	}
}

tuck_TrafficLightSlot: rawptr

drain_tuck_TrafficLight :: proc() -> bool {
	msg: tuck_TrafficLightMsg
	didWork := false
	for rt.dequeue(&tuck_TrafficLightSingleton.mailbox, &msg) {
		handleMsg_tuck_TrafficLight(&tuck_TrafficLightSingleton, msg)
		rt.tuckCheckWaiters()
		didWork = true
	}
	return didWork
}

sendNext_tuck_TrafficLight :: proc(self: ^tuck_TrafficLight) {
	_ = rt.enqueue(&self.mailbox, tuck_TrafficLightMsg{tuckTag = .msgNext})
}

main :: proc() {
	rt.tuckAsyncInit()
	tuck_TrafficLightSlot = rt.tuckStartActor(drain_tuck_TrafficLight)
	rt.tuckDrainActors()
}
