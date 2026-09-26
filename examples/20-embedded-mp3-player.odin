#+feature dynamic-literals
package main

import rt "./tuckrt"

tuckˑtypeˑHz :: distinct u32

tuckˑtypeˑMilliseconds :: distinct u32

tuckˑregistryˑSystemEventsKind :: enum { PlaybackStarted, PlaybackStopped, HardwareError }
tuckˑregistryˑSystemEvents :: struct {
	tuckTag: tuckˑregistryˑSystemEventsKind,
	code: u8,
}

latesttuckˑregistryˑSystemEvents: tuckˑregistryˑSystemEvents

raise_tuckˑregistryˑSystemEvents_PlaybackStarted :: proc() {
	latesttuckˑregistryˑSystemEvents = tuckˑregistryˑSystemEvents{tuckTag = .PlaybackStarted}
	tuckˑfnˑSystemEvents_PlaybackStarted()
}

raise_tuckˑregistryˑSystemEvents_PlaybackStopped :: proc() {
	latesttuckˑregistryˑSystemEvents = tuckˑregistryˑSystemEvents{tuckTag = .PlaybackStopped}
	tuckˑfnˑSystemEvents_PlaybackStopped()
}

raise_tuckˑregistryˑSystemEvents_HardwareError :: proc(code: u8) {
	latesttuckˑregistryˑSystemEvents = tuckˑregistryˑSystemEvents{tuckTag = .HardwareError, code = code}
	tuckˑfnˑSystemEvents_HardwareError(code)
}


tuckˑregisterˑDAC_CR := cast(^u32)(uintptr(0x40007400))
tuckˑregisterˑDAC_CR_EN_SHIFT :: 0
tuckˑregisterˑDAC_CR_BOFF_SHIFT :: 1
tuckˑregisterˑDAC_CR_EN_get :: proc() -> bool {
	return (tuckˑregisterˑDAC_CR^ & (u32(1) << u32(tuckˑregisterˑDAC_CR_EN_SHIFT))) != 0
}
tuckˑregisterˑDAC_CR_EN_set :: proc(on: bool) {
	mask := u32(1) << u32(tuckˑregisterˑDAC_CR_EN_SHIFT)
	if on { tuckˑregisterˑDAC_CR^ |= mask } else { tuckˑregisterˑDAC_CR^ &~= mask }
}
tuckˑregisterˑDAC_CR_BOFF_get :: proc() -> bool {
	return (tuckˑregisterˑDAC_CR^ & (u32(1) << u32(tuckˑregisterˑDAC_CR_BOFF_SHIFT))) != 0
}
tuckˑregisterˑDAC_CR_BOFF_set :: proc(on: bool) {
	mask := u32(1) << u32(tuckˑregisterˑDAC_CR_BOFF_SHIFT)
	if on { tuckˑregisterˑDAC_CR^ |= mask } else { tuckˑregisterˑDAC_CR^ &~= mask }
}

tuckˑregisterˑDMA1_CH3 := cast(^u32)(uintptr(0x40020030))
tuckˑregisterˑDMA1_CH3_EN_SHIFT :: 0
tuckˑregisterˑDMA1_CH3_TCIE_SHIFT :: 1
tuckˑregisterˑDMA1_CH3_EN_get :: proc() -> bool {
	return (tuckˑregisterˑDMA1_CH3^ & (u32(1) << u32(tuckˑregisterˑDMA1_CH3_EN_SHIFT))) != 0
}
tuckˑregisterˑDMA1_CH3_EN_set :: proc(on: bool) {
	mask := u32(1) << u32(tuckˑregisterˑDMA1_CH3_EN_SHIFT)
	if on { tuckˑregisterˑDMA1_CH3^ |= mask } else { tuckˑregisterˑDMA1_CH3^ &~= mask }
}
tuckˑregisterˑDMA1_CH3_TCIE_get :: proc() -> bool {
	return (tuckˑregisterˑDMA1_CH3^ & (u32(1) << u32(tuckˑregisterˑDMA1_CH3_TCIE_SHIFT))) != 0
}
tuckˑregisterˑDMA1_CH3_TCIE_set :: proc(on: bool) {
	mask := u32(1) << u32(tuckˑregisterˑDMA1_CH3_TCIE_SHIFT)
	if on { tuckˑregisterˑDMA1_CH3^ |= mask } else { tuckˑregisterˑDMA1_CH3^ &~= mask }
}

tuckˑtypeˑPlayerState_Idle :: struct {}
tuckˑtypeˑPlayerState_Decoding :: struct {
	sampleRate: tuckˑtypeˑHz,
}
tuckˑtypeˑPlayerState_Paused :: struct {}
tuckˑtypeˑPlayerState :: union {tuckˑtypeˑPlayerState_Idle, tuckˑtypeˑPlayerState_Decoding, tuckˑtypeˑPlayerState_Paused}
tuckˑtypeˑPlayerStateKind :: enum { Idle, Decoding, Paused }
tag_tuckˑtypeˑPlayerState :: proc(v: tuckˑtypeˑPlayerState) -> tuckˑtypeˑPlayerStateKind {
	switch _ in v {
	case tuckˑtypeˑPlayerState_Idle: return .Idle
	case tuckˑtypeˑPlayerState_Decoding: return .Decoding
	case tuckˑtypeˑPlayerState_Paused: return .Paused
	}
	return .Idle
}

tuckˑtypeˑPlayerState_eq :: proc(a, b: tuckˑtypeˑPlayerState) -> bool {
  if av, aok := a.(tuckˑtypeˑPlayerState_Idle); aok {
    _ = av
    bv, bok := b.(tuckˑtypeˑPlayerState_Idle)
    _ = bv
    if !bok { return false }
    return true
  }
  if av, aok := a.(tuckˑtypeˑPlayerState_Decoding); aok {
    _ = av
    bv, bok := b.(tuckˑtypeˑPlayerState_Decoding)
    _ = bv
    if !bok { return false }
    if av.sampleRate != bv.sampleRate { return false }
    return true
  }
  if av, aok := a.(tuckˑtypeˑPlayerState_Paused); aok {
    _ = av
    bv, bok := b.(tuckˑtypeˑPlayerState_Paused)
    _ = bv
    if !bok { return false }
    return true
  }
  return false
}
canTransition_tuckˑtypeˑPlayerState :: proc(frm: tuckˑtypeˑPlayerStateKind, to: tuckˑtypeˑPlayerStateKind) -> bool {
	switch frm {
	case .Idle: return to == .Decoding
	case .Decoding: return to == .Paused || to == .Idle
	case .Paused: return to == .Decoding || to == .Idle
	}
	return false
}
transitionTo_tuckˑtypeˑPlayerState :: proc(self: ^tuckˑtypeˑPlayerState, target: tuckˑtypeˑPlayerState) {
	assert(canTransition_tuckˑtypeˑPlayerState(tag_tuckˑtypeˑPlayerState(self^), tag_tuckˑtypeˑPlayerState(target)), "Invalid transition")
	self^ = target
}

tuckˑpoolˑBufferPool: rt.ObjectPool([512]u8, 4)

tuckˑtypeˑVolume :: struct {
	level: u8,
}
validate_tuckˑtypeˑVolume :: proc(self: tuckˑtypeˑVolume) {
	assert((self.level <= 100))
}
__validated_tuckˑtypeˑVolume :: proc(v: tuckˑtypeˑVolume) -> tuckˑtypeˑVolume {
	validate_tuckˑtypeˑVolume(v)
	return v
}

tuckˑtaskˑstreamReader :: proc(streamId: u8, chunks: [dynamic]u32) -> rt.TuckResult(rt.TuckUnit) {
  for tuckˑvˑi in chunks {
      tuckˑvˑbuf := rt.acquire(&tuckˑpoolˑBufferPool)
      if !(tuckˑvˑbuf.status == .Ok) {
          return rt.tokVoid()
      }
      tuckˑregisterˑDMA1_CH3_EN_set(true)
      rt.release(&tuckˑpoolˑBufferPool, tuckˑvˑbuf.value)
  }
  return {}
}

tuckˑactorˑDecoderMsgKind :: enum { msgPlay, msgPause, msgStop }
tuckˑactorˑDecoderMsg :: struct {
	tuckTag: tuckˑactorˑDecoderMsgKind,
	rate: tuckˑtypeˑHz,
}
tuckˑactorˑDecoder :: struct {
	state: tuckˑtypeˑPlayerState,
	vol: tuckˑtypeˑVolume,
	mailbox: rt.Mailbox(tuckˑactorˑDecoderMsg, 8),
}

tuckˑactorˑDecoderSingleton: tuckˑactorˑDecoder

handleMsg_tuckˑactorˑDecoder :: proc(self: ^tuckˑactorˑDecoder, msg: tuckˑactorˑDecoderMsg) {
	switch msg.tuckTag {
	case .msgPlay:
		rate := msg.rate
    switch v in self.state
    {
    case tuckˑtypeˑPlayerState_Idle:
        self.state = tuckˑtypeˑPlayerState_Decoding{sampleRate = rate}
        raise_tuckˑregistryˑSystemEvents_PlaybackStarted()
        tuckˑregisterˑDAC_CR_EN_set(true)
    case tuckˑtypeˑPlayerState_Paused:
        self.state = tuckˑtypeˑPlayerState_Decoding{sampleRate = rate}
        raise_tuckˑregistryˑSystemEvents_PlaybackStarted()
        tuckˑregisterˑDAC_CR_EN_set(true)
    case tuckˑtypeˑPlayerState_Decoding: ;
    }
	case .msgPause:
    switch v in self.state
    {
    case tuckˑtypeˑPlayerState_Decoding: self.state = tuckˑtypeˑPlayerState_Paused{};
    case tuckˑtypeˑPlayerState_Idle: ;
    case tuckˑtypeˑPlayerState_Paused: ;
    }
    tuckˑregisterˑDAC_CR_EN_set(false)
	case .msgStop:
    self.state = tuckˑtypeˑPlayerState_Idle{}
    raise_tuckˑregistryˑSystemEvents_PlaybackStopped()
    tuckˑregisterˑDAC_CR_EN_set(false)
	}
}

tuckˑactorˑDecoderSlot: rawptr

drain_tuckˑactorˑDecoder :: proc() -> bool {
	didWork := false
	batch, n := rt.takeBatch(&tuckˑactorˑDecoderSingleton.mailbox)
	for i in 0 ..< n {
		handleMsg_tuckˑactorˑDecoder(&tuckˑactorˑDecoderSingleton, batch[i])
		rt.tuckCheckWaiters()
		didWork = true
	}
	return didWork
}

sendPlay_tuckˑactorˑDecoder :: proc(self: ^tuckˑactorˑDecoder, rate: tuckˑtypeˑHz) {
	_ = rt.enqueue(&self.mailbox, tuckˑactorˑDecoderMsg{tuckTag = .msgPlay, rate = rate})
	rt.tuckNotifySend(tuckˑactorˑDecoderSlot)
}

sendPause_tuckˑactorˑDecoder :: proc(self: ^tuckˑactorˑDecoder) {
	_ = rt.enqueue(&self.mailbox, tuckˑactorˑDecoderMsg{tuckTag = .msgPause})
	rt.tuckNotifySend(tuckˑactorˑDecoderSlot)
}

sendStop_tuckˑactorˑDecoder :: proc(self: ^tuckˑactorˑDecoder) {
	_ = rt.enqueue(&self.mailbox, tuckˑactorˑDecoderMsg{tuckTag = .msgStop})
	rt.tuckNotifySend(tuckˑactorˑDecoderSlot)
}

tuckˑfnˑSystemEvents_PlaybackStarted :: proc () {
  tuckˑregisterˑDAC_CR_EN_set(true)
}

tuckˑfnˑSystemEvents_PlaybackStopped :: proc () {
  tuckˑregisterˑDAC_CR_EN_set(false)
}

tuckˑfnˑSystemEvents_HardwareError :: proc (code: u8) {
  tuckˑvˑfailed := code
  tuckˑregisterˑDAC_CR_EN_set(false)
}

tuckˑfnˑmain :: proc () {

}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	assert((size_of(tuckˑtypeˑVolume) == 1))
	tuckˑactorˑDecoderSingleton.state = tuckˑtypeˑPlayerState_Idle{}
	tuckˑactorˑDecoderSingleton.vol = __validated_tuckˑtypeˑVolume(tuckˑtypeˑVolume{level = u8(80)})
	rt.tuckAsyncInit()
	tuckˑactorˑDecoderSlot = rt.tuckStartActor(drain_tuckˑactorˑDecoder)
	tuckˑfnˑmain()
	rt.tuckRun()
	rt.tuckDrainActors()
	rt.tuckTrackCheck()
}
