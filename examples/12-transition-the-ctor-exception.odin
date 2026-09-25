#+feature dynamic-literals
package main

tuck_type_Config :: struct {
	url: string,
}

tuck_type_Feed :: struct {
	title: string,
}

tuck_type_Socket :: struct {
	fd: int,
}

tuck_type_PlayerState_Unloaded :: struct {
	config: tuck_type_Config,
}
tuck_type_PlayerState_Loading :: struct {
	config: tuck_type_Config,
	progress: int,
}
tuck_type_PlayerState_Ready :: struct {
	config: tuck_type_Config,
	feed: tuck_type_Feed,
}
tuck_type_PlayerState :: union {tuck_type_PlayerState_Unloaded, tuck_type_PlayerState_Loading, tuck_type_PlayerState_Ready}
tuck_type_PlayerStateKind :: enum { Unloaded, Loading, Ready }
tag_tuck_type_PlayerState :: proc(v: tuck_type_PlayerState) -> tuck_type_PlayerStateKind {
	switch _ in v {
	case tuck_type_PlayerState_Unloaded: return .Unloaded
	case tuck_type_PlayerState_Loading: return .Loading
	case tuck_type_PlayerState_Ready: return .Ready
	}
	return .Unloaded
}

tuck_type_PlayerState_eq :: proc(a, b: tuck_type_PlayerState) -> bool {
  if av, aok := a.(tuck_type_PlayerState_Unloaded); aok {
    _ = av
    bv, bok := b.(tuck_type_PlayerState_Unloaded)
    _ = bv
    if !bok { return false }
    if av.config != bv.config { return false }
    return true
  }
  if av, aok := a.(tuck_type_PlayerState_Loading); aok {
    _ = av
    bv, bok := b.(tuck_type_PlayerState_Loading)
    _ = bv
    if !bok { return false }
    if av.config != bv.config { return false }
    if av.progress != bv.progress { return false }
    return true
  }
  if av, aok := a.(tuck_type_PlayerState_Ready); aok {
    _ = av
    bv, bok := b.(tuck_type_PlayerState_Ready)
    _ = bv
    if !bok { return false }
    if av.config != bv.config { return false }
    if av.feed != bv.feed { return false }
    return true
  }
  return false
}
canTransition_tuck_type_PlayerState :: proc(frm: tuck_type_PlayerStateKind, to: tuck_type_PlayerStateKind) -> bool {
	switch frm {
	case .Unloaded: return to == .Loading
	case .Loading: return to == .Ready || to == .Unloaded
	case .Ready: return false
	}
	return false
}
transitionTo_tuck_type_PlayerState :: proc(self: ^tuck_type_PlayerState, target: tuck_type_PlayerState) {
	assert(canTransition_tuck_type_PlayerState(tag_tuck_type_PlayerState(self^), tag_tuck_type_PlayerState(target)), "Invalid transition")
	self^ = target
}

tuck_type_MqttSession_Disconnected :: struct {}
tuck_type_MqttSession_Connecting :: struct {
	host: string,
	port: u16,
}
tuck_type_MqttSession_Connected :: struct {
	socket: tuck_type_Socket,
	keepalive: u16,
}
tuck_type_MqttSession_Subscribing :: struct {
	socket: tuck_type_Socket,
	topic: string,
}
tuck_type_MqttSession :: union {tuck_type_MqttSession_Disconnected, tuck_type_MqttSession_Connecting, tuck_type_MqttSession_Connected, tuck_type_MqttSession_Subscribing}
tuck_type_MqttSessionKind :: enum { Disconnected, Connecting, Connected, Subscribing }
tag_tuck_type_MqttSession :: proc(v: tuck_type_MqttSession) -> tuck_type_MqttSessionKind {
	switch _ in v {
	case tuck_type_MqttSession_Disconnected: return .Disconnected
	case tuck_type_MqttSession_Connecting: return .Connecting
	case tuck_type_MqttSession_Connected: return .Connected
	case tuck_type_MqttSession_Subscribing: return .Subscribing
	}
	return .Disconnected
}

tuck_type_MqttSession_eq :: proc(a, b: tuck_type_MqttSession) -> bool {
  if av, aok := a.(tuck_type_MqttSession_Disconnected); aok {
    _ = av
    bv, bok := b.(tuck_type_MqttSession_Disconnected)
    _ = bv
    if !bok { return false }
    return true
  }
  if av, aok := a.(tuck_type_MqttSession_Connecting); aok {
    _ = av
    bv, bok := b.(tuck_type_MqttSession_Connecting)
    _ = bv
    if !bok { return false }
    if av.host != bv.host { return false }
    if av.port != bv.port { return false }
    return true
  }
  if av, aok := a.(tuck_type_MqttSession_Connected); aok {
    _ = av
    bv, bok := b.(tuck_type_MqttSession_Connected)
    _ = bv
    if !bok { return false }
    if av.socket != bv.socket { return false }
    if av.keepalive != bv.keepalive { return false }
    return true
  }
  if av, aok := a.(tuck_type_MqttSession_Subscribing); aok {
    _ = av
    bv, bok := b.(tuck_type_MqttSession_Subscribing)
    _ = bv
    if !bok { return false }
    if av.socket != bv.socket { return false }
    if av.topic != bv.topic { return false }
    return true
  }
  return false
}
canTransition_tuck_type_MqttSession :: proc(frm: tuck_type_MqttSessionKind, to: tuck_type_MqttSessionKind) -> bool {
	switch frm {
	case .Disconnected: return to == .Connecting
	case .Connecting: return to == .Connected || to == .Disconnected
	case .Connected: return to == .Subscribing
	case .Subscribing: return to == .Connected
	}
	return false
}
transitionTo_tuck_type_MqttSession :: proc(self: ^tuck_type_MqttSession, target: tuck_type_MqttSession) {
	assert(canTransition_tuck_type_MqttSession(tag_tuck_type_MqttSession(self^), tag_tuck_type_MqttSession(target)), "Invalid transition")
	self^ = target
}

tuck_fn_main :: proc () {
  tuck_config := tuck_type_Config{url = "https://example.com"}
  tuck_feed := tuck_type_Feed{title = "Deep Dive"}
  tuck_p: tuck_type_PlayerState = tuck_type_PlayerState_Ready{config = tuck_config, feed = tuck_feed}
  tuck_fresh: tuck_type_MqttSession = tuck_type_MqttSession_Disconnected{}
  tuck_socket := tuck_type_Socket{fd = 3}
  tuck_session: tuck_type_MqttSession = tuck_type_MqttSession_Connected{socket = tuck_socket, keepalive = u16(60)}
  return
}

main :: proc() {
	tuck_fn_main()
}
