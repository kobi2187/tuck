package main

import rt "./tuckrt"

tuck_TrafficLightStateKind :: enum { Red, Yellow, Green }

tuck_TrafficLightMsgKind :: enum { msgNext }
tuck_TrafficLightMsg :: struct {
	kind: tuck_TrafficLightMsgKind,
}
tuck_TrafficLight :: struct {
	state: tuck_TrafficLightStateKind,
	mailbox: rt.Mailbox(tuck_TrafficLightMsg, 4),
}

tuck_TrafficLightSingleton: tuck_TrafficLight

handleMsg_tuck_TrafficLight :: proc(self: ^tuck_TrafficLight, msg: tuck_TrafficLightMsg) {
	switch msg.kind {
	case .msgNext:
    self.state = ((self.state == .Red) ? .Green : ((self.state == .Green) ? .Yellow : .Red))
	}
}

drain_tuck_TrafficLight :: proc() {
	for {
		msg: tuck_TrafficLightMsg
		for rt.dequeue(&tuck_TrafficLightSingleton.mailbox, &msg) {
			handleMsg_tuck_TrafficLight(&tuck_TrafficLightSingleton, msg)
		}
		rt.coroYield()
	}
}

sendNext_tuck_TrafficLight :: proc(self: ^tuck_TrafficLight) {
	_ = rt.enqueue(&self.mailbox, tuck_TrafficLightMsg{kind = .msgNext})
}

main :: proc() {
	rt.tuckAsyncInit()
	rt.tuckStartActor(drain_tuck_TrafficLight)
}
