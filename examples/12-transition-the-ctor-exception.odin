#+feature dynamic-literals
package main

import rt "./tuckrt"

tuckG_0_copy :: proc(value: $G) -> G {
	return rt.tuckStrOwned(value)
}
tuckG_0_drop :: proc(value: $G) {
	delete(value)
}
tuckG_0_reset :: proc(value: ^$G) { tuckG_0_drop(value^); value^ = {} }


tuckG_3_copy :: proc(value: $G) -> G {
	out := value
	out.url = tuckG_0_copy(value.url)
	return out
}
tuckG_3_drop :: proc(value: $G) {
	tuckG_0_drop(value.url)
}
tuckG_3_reset :: proc(value: ^$G) { tuckG_3_drop(value^); value^ = {} }


tuckG_2_copy :: proc(value: $G) -> G {
	out := value
	out.config = tuckG_3_copy(value.config)
	return out
}
tuckG_2_drop :: proc(value: $G) {
	tuckG_3_drop(value.config)
}
tuckG_2_reset :: proc(value: ^$G) { tuckG_2_drop(value^); value^ = {} }


tuckG_4_copy :: proc(value: $G) -> G {
	out := value
	out.config = tuckG_3_copy(value.config)
	return out
}
tuckG_4_drop :: proc(value: $G) {
	tuckG_3_drop(value.config)
}
tuckG_4_reset :: proc(value: ^$G) { tuckG_4_drop(value^); value^ = {} }


tuckG_6_copy :: proc(value: $G) -> G {
	out := value
	out.title = tuckG_0_copy(value.title)
	return out
}
tuckG_6_drop :: proc(value: $G) {
	tuckG_0_drop(value.title)
}
tuckG_6_reset :: proc(value: ^$G) { tuckG_6_drop(value^); value^ = {} }


tuckG_5_copy :: proc(value: $G) -> G {
	out := value
	out.config = tuckG_3_copy(value.config)
	out.feed = tuckG_6_copy(value.feed)
	return out
}
tuckG_5_drop :: proc(value: $G) {
	tuckG_3_drop(value.config)
	tuckG_6_drop(value.feed)
}
tuckG_5_reset :: proc(value: ^$G) { tuckG_5_drop(value^); value^ = {} }


tuckG_1_copy :: proc(value: $G) -> G {
	out: G
	switch payload in value {
	case tuckˑtypeˑPlayerState_Unloaded: out = tuckG_2_copy(payload)
	case tuckˑtypeˑPlayerState_Loading: out = tuckG_4_copy(payload)
	case tuckˑtypeˑPlayerState_Ready: out = tuckG_5_copy(payload)
	}
	return out
}
tuckG_1_drop :: proc(value: $G) {
	switch payload in value {
	case tuckˑtypeˑPlayerState_Unloaded: tuckG_2_drop(payload)
	case tuckˑtypeˑPlayerState_Loading: tuckG_4_drop(payload)
	case tuckˑtypeˑPlayerState_Ready: tuckG_5_drop(payload)
	}
}
tuckG_1_reset :: proc(value: ^$G) { tuckG_1_drop(value^); value^ = {} }


tuckG_8_copy :: proc(value: $G) -> G {
	return value
}
tuckG_8_drop :: proc(value: $G) {
}
tuckG_8_reset :: proc(value: ^$G) { tuckG_8_drop(value^); value^ = {} }


tuckG_9_copy :: proc(value: $G) -> G {
	out := value
	out.host = tuckG_0_copy(value.host)
	return out
}
tuckG_9_drop :: proc(value: $G) {
	tuckG_0_drop(value.host)
}
tuckG_9_reset :: proc(value: ^$G) { tuckG_9_drop(value^); value^ = {} }


tuckG_10_copy :: proc(value: $G) -> G {
	return value
}
tuckG_10_drop :: proc(value: $G) {
}
tuckG_10_reset :: proc(value: ^$G) { tuckG_10_drop(value^); value^ = {} }


tuckG_11_copy :: proc(value: $G) -> G {
	out := value
	out.topic = tuckG_0_copy(value.topic)
	return out
}
tuckG_11_drop :: proc(value: $G) {
	tuckG_0_drop(value.topic)
}
tuckG_11_reset :: proc(value: ^$G) { tuckG_11_drop(value^); value^ = {} }


tuckG_7_copy :: proc(value: $G) -> G {
	out: G
	switch payload in value {
	case tuckˑtypeˑMqttSession_Disconnected: out = tuckG_8_copy(payload)
	case tuckˑtypeˑMqttSession_Connecting: out = tuckG_9_copy(payload)
	case tuckˑtypeˑMqttSession_Connected: out = tuckG_10_copy(payload)
	case tuckˑtypeˑMqttSession_Subscribing: out = tuckG_11_copy(payload)
	}
	return out
}
tuckG_7_drop :: proc(value: $G) {
	switch payload in value {
	case tuckˑtypeˑMqttSession_Disconnected: tuckG_8_drop(payload)
	case tuckˑtypeˑMqttSession_Connecting: tuckG_9_drop(payload)
	case tuckˑtypeˑMqttSession_Connected: tuckG_10_drop(payload)
	case tuckˑtypeˑMqttSession_Subscribing: tuckG_11_drop(payload)
	}
}
tuckG_7_reset :: proc(value: ^$G) { tuckG_7_drop(value^); value^ = {} }


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
  tuckˑvˑconfig := tuckˑtypeˑConfig{url = tuckG_0_copy("https://example.com")}
  tuckˑvˑfeed := tuckˑtypeˑFeed{title = tuckG_0_copy("Deep Dive")}
  tuckˑvˑp: tuckˑtypeˑPlayerState = tuckˑtypeˑPlayerState_Ready{config = tuckˑvˑconfig, feed = tuckˑvˑfeed}
  defer tuckG_1_drop(tuckˑvˑp)
  tuckˑvˑfresh: tuckˑtypeˑMqttSession = tuckˑtypeˑMqttSession_Disconnected{}
  defer tuckG_7_drop(tuckˑvˑfresh)
  tuckˑvˑsocket := tuckˑtypeˑSocket{fd = 3}
  tuckˑvˑsession: tuckˑtypeˑMqttSession = tuckˑtypeˑMqttSession_Connected{socket = tuckˑvˑsocket, keepalive = u16(60)}
  defer tuckG_7_drop(tuckˑvˑsession)
  return
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuckˑfnˑmain()
	rt.tuckTrackCheck()
}
