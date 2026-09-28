#+feature dynamic-literals
package main

tuckˑtypeˑConfig :: struct {
	url: string,
}

tuckˑtypeˑFeed :: struct {
	title: string,
}

tuckˑtypeˑSocket :: struct {
	fd: int,
}

tuckˑtypeˑPlayerState_Unloaded :: struct {
	config: tuckˑtypeˑConfig,
}
tuckˑtypeˑPlayerState_Loading :: struct {
	config: tuckˑtypeˑConfig,
	progress: int,
}
tuckˑtypeˑPlayerState_Ready :: struct {
	config: tuckˑtypeˑConfig,
	feed: tuckˑtypeˑFeed,
}
tuckˑtypeˑPlayerState :: union {tuckˑtypeˑPlayerState_Unloaded, tuckˑtypeˑPlayerState_Loading, tuckˑtypeˑPlayerState_Ready}
tuckˑtypeˑPlayerStateKind :: enum { Unloaded, Loading, Ready }
tag_tuckˑtypeˑPlayerState :: proc(v: tuckˑtypeˑPlayerState) -> tuckˑtypeˑPlayerStateKind {
	switch _ in v {
	case tuckˑtypeˑPlayerState_Unloaded: return .Unloaded
	case tuckˑtypeˑPlayerState_Loading: return .Loading
	case tuckˑtypeˑPlayerState_Ready: return .Ready
	}
	return .Unloaded
}

tuckˑtypeˑPlayerState_eq :: proc(a, b: tuckˑtypeˑPlayerState) -> bool {
  if av, aok := a.(tuckˑtypeˑPlayerState_Unloaded); aok {
    _ = av
    bv, bok := b.(tuckˑtypeˑPlayerState_Unloaded)
    _ = bv
    if !bok { return false }
    if av.config != bv.config { return false }
    return true
  }
  if av, aok := a.(tuckˑtypeˑPlayerState_Loading); aok {
    _ = av
    bv, bok := b.(tuckˑtypeˑPlayerState_Loading)
    _ = bv
    if !bok { return false }
    if av.config != bv.config { return false }
    if av.progress != bv.progress { return false }
    return true
  }
  if av, aok := a.(tuckˑtypeˑPlayerState_Ready); aok {
    _ = av
    bv, bok := b.(tuckˑtypeˑPlayerState_Ready)
    _ = bv
    if !bok { return false }
    if av.config != bv.config { return false }
    if av.feed != bv.feed { return false }
    return true
  }
  return false
}
canTransition_tuckˑtypeˑPlayerState :: proc(frm: tuckˑtypeˑPlayerStateKind, to: tuckˑtypeˑPlayerStateKind) -> bool {
	switch frm {
	case .Unloaded: return to == .Loading
	case .Loading: return to == .Ready || to == .Unloaded
	case .Ready: return false
	}
	return false
}
transitionTo_tuckˑtypeˑPlayerState :: proc(self: ^tuckˑtypeˑPlayerState, target: tuckˑtypeˑPlayerState) {
	assert(canTransition_tuckˑtypeˑPlayerState(tag_tuckˑtypeˑPlayerState(self^), tag_tuckˑtypeˑPlayerState(target)), "Invalid transition")
	self^ = target
}

tuckˑtypeˑMqttSession_Disconnected :: struct {}
tuckˑtypeˑMqttSession_Connecting :: struct {
	host: string,
	port: u16,
}
tuckˑtypeˑMqttSession_Connected :: struct {
	socket: tuckˑtypeˑSocket,
	keepalive: u16,
}
tuckˑtypeˑMqttSession_Subscribing :: struct {
	socket: tuckˑtypeˑSocket,
	topic: string,
}
tuckˑtypeˑMqttSession :: union {tuckˑtypeˑMqttSession_Disconnected, tuckˑtypeˑMqttSession_Connecting, tuckˑtypeˑMqttSession_Connected, tuckˑtypeˑMqttSession_Subscribing}
tuckˑtypeˑMqttSessionKind :: enum { Disconnected, Connecting, Connected, Subscribing }
tag_tuckˑtypeˑMqttSession :: proc(v: tuckˑtypeˑMqttSession) -> tuckˑtypeˑMqttSessionKind {
	switch _ in v {
	case tuckˑtypeˑMqttSession_Disconnected: return .Disconnected
	case tuckˑtypeˑMqttSession_Connecting: return .Connecting
	case tuckˑtypeˑMqttSession_Connected: return .Connected
	case tuckˑtypeˑMqttSession_Subscribing: return .Subscribing
	}
	return .Disconnected
}

tuckˑtypeˑMqttSession_eq :: proc(a, b: tuckˑtypeˑMqttSession) -> bool {
  if av, aok := a.(tuckˑtypeˑMqttSession_Disconnected); aok {
    _ = av
    bv, bok := b.(tuckˑtypeˑMqttSession_Disconnected)
    _ = bv
    if !bok { return false }
    return true
  }
  if av, aok := a.(tuckˑtypeˑMqttSession_Connecting); aok {
    _ = av
    bv, bok := b.(tuckˑtypeˑMqttSession_Connecting)
    _ = bv
    if !bok { return false }
    if av.host != bv.host { return false }
    if av.port != bv.port { return false }
    return true
  }
  if av, aok := a.(tuckˑtypeˑMqttSession_Connected); aok {
    _ = av
    bv, bok := b.(tuckˑtypeˑMqttSession_Connected)
    _ = bv
    if !bok { return false }
    if av.socket != bv.socket { return false }
    if av.keepalive != bv.keepalive { return false }
    return true
  }
  if av, aok := a.(tuckˑtypeˑMqttSession_Subscribing); aok {
    _ = av
    bv, bok := b.(tuckˑtypeˑMqttSession_Subscribing)
    _ = bv
    if !bok { return false }
    if av.socket != bv.socket { return false }
    if av.topic != bv.topic { return false }
    return true
  }
  return false
}
canTransition_tuckˑtypeˑMqttSession :: proc(frm: tuckˑtypeˑMqttSessionKind, to: tuckˑtypeˑMqttSessionKind) -> bool {
	switch frm {
	case .Disconnected: return to == .Connecting
	case .Connecting: return to == .Connected || to == .Disconnected
	case .Connected: return to == .Subscribing
	case .Subscribing: return to == .Connected
	}
	return false
}
transitionTo_tuckˑtypeˑMqttSession :: proc(self: ^tuckˑtypeˑMqttSession, target: tuckˑtypeˑMqttSession) {
	assert(canTransition_tuckˑtypeˑMqttSession(tag_tuckˑtypeˑMqttSession(self^), tag_tuckˑtypeˑMqttSession(target)), "Invalid transition")
	self^ = target
}

tuckˑfnˑmain :: proc () {
  tuckˑvˑconfig := tuckˑtypeˑConfig{url = "https://example.com"}
  tuckˑvˑfeed := tuckˑtypeˑFeed{title = "Deep Dive"}
  tuckˑvˑp: tuckˑtypeˑPlayerState = tuckˑtypeˑPlayerState_Ready{config = tuckˑvˑconfig, feed = tuckˑvˑfeed}
  tuckˑvˑfresh: tuckˑtypeˑMqttSession = tuckˑtypeˑMqttSession_Disconnected{}
  tuckˑvˑsocket := tuckˑtypeˑSocket{fd = 3}
  tuckˑvˑsession: tuckˑtypeˑMqttSession = tuckˑtypeˑMqttSession_Connected{socket = tuckˑvˑsocket, keepalive = u16(60)}
  return
}

main :: proc() {
	tuckˑfnˑmain()
}
