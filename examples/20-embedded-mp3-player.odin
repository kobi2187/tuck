#+feature dynamic-literals
package main

import rt "./tuckrt"

tuck_Hz :: distinct u32

tuck_Milliseconds :: distinct u32

tuck_SystemEventsKind :: enum { PlaybackStarted, PlaybackStopped, HardwareError }
tuck_SystemEvents :: struct {
	tuckTag: tuck_SystemEventsKind,
	code: u8,
}

latesttuck_SystemEvents: tuck_SystemEvents

raise_tuck_SystemEvents_PlaybackStarted :: proc() {
	latesttuck_SystemEvents = tuck_SystemEvents{tuckTag = .PlaybackStarted}
	tuck_SystemEvents_PlaybackStarted()
}

raise_tuck_SystemEvents_PlaybackStopped :: proc() {
	latesttuck_SystemEvents = tuck_SystemEvents{tuckTag = .PlaybackStopped}
	tuck_SystemEvents_PlaybackStopped()
}

raise_tuck_SystemEvents_HardwareError :: proc(code: u8) {
	latesttuck_SystemEvents = tuck_SystemEvents{tuckTag = .HardwareError, code = code}
	tuck_SystemEvents_HardwareError(code)
}


tuck_DAC_CR := cast(^u32)(uintptr(0x40007400))
tuck_DAC_CR_EN_SHIFT :: 0
tuck_DAC_CR_BOFF_SHIFT :: 1
tuck_DAC_CR_EN_get :: proc() -> bool {
	return (tuck_DAC_CR^ & (u32(1) << u32(tuck_DAC_CR_EN_SHIFT))) != 0
}
tuck_DAC_CR_EN_set :: proc(on: bool) {
	mask := u32(1) << u32(tuck_DAC_CR_EN_SHIFT)
	if on { tuck_DAC_CR^ |= mask } else { tuck_DAC_CR^ &~= mask }
}
tuck_DAC_CR_BOFF_get :: proc() -> bool {
	return (tuck_DAC_CR^ & (u32(1) << u32(tuck_DAC_CR_BOFF_SHIFT))) != 0
}
tuck_DAC_CR_BOFF_set :: proc(on: bool) {
	mask := u32(1) << u32(tuck_DAC_CR_BOFF_SHIFT)
	if on { tuck_DAC_CR^ |= mask } else { tuck_DAC_CR^ &~= mask }
}

tuck_DMA1_CH3 := cast(^u32)(uintptr(0x40020030))
tuck_DMA1_CH3_EN_SHIFT :: 0
tuck_DMA1_CH3_TCIE_SHIFT :: 1
tuck_DMA1_CH3_EN_get :: proc() -> bool {
	return (tuck_DMA1_CH3^ & (u32(1) << u32(tuck_DMA1_CH3_EN_SHIFT))) != 0
}
tuck_DMA1_CH3_EN_set :: proc(on: bool) {
	mask := u32(1) << u32(tuck_DMA1_CH3_EN_SHIFT)
	if on { tuck_DMA1_CH3^ |= mask } else { tuck_DMA1_CH3^ &~= mask }
}
tuck_DMA1_CH3_TCIE_get :: proc() -> bool {
	return (tuck_DMA1_CH3^ & (u32(1) << u32(tuck_DMA1_CH3_TCIE_SHIFT))) != 0
}
tuck_DMA1_CH3_TCIE_set :: proc(on: bool) {
	mask := u32(1) << u32(tuck_DMA1_CH3_TCIE_SHIFT)
	if on { tuck_DMA1_CH3^ |= mask } else { tuck_DMA1_CH3^ &~= mask }
}

tuck_PlayerState_Idle :: struct {}
tuck_PlayerState_Decoding :: struct {
	sampleRate: tuck_Hz,
}
tuck_PlayerState_Paused :: struct {}
tuck_PlayerState :: union {tuck_PlayerState_Idle, tuck_PlayerState_Decoding, tuck_PlayerState_Paused}
tuck_PlayerStateKind :: enum { Idle, Decoding, Paused }
tag_tuck_PlayerState :: proc(v: tuck_PlayerState) -> tuck_PlayerStateKind {
	switch _ in v {
	case tuck_PlayerState_Idle: return .Idle
	case tuck_PlayerState_Decoding: return .Decoding
	case tuck_PlayerState_Paused: return .Paused
	}
	return .Idle
}

tuck_PlayerState_eq :: proc(a, b: tuck_PlayerState) -> bool {
  if av, aok := a.(tuck_PlayerState_Idle); aok {
    _ = av
    bv, bok := b.(tuck_PlayerState_Idle)
    _ = bv
    if !bok { return false }
    return true
  }
  if av, aok := a.(tuck_PlayerState_Decoding); aok {
    _ = av
    bv, bok := b.(tuck_PlayerState_Decoding)
    _ = bv
    if !bok { return false }
    if av.sampleRate != bv.sampleRate { return false }
    return true
  }
  if av, aok := a.(tuck_PlayerState_Paused); aok {
    _ = av
    bv, bok := b.(tuck_PlayerState_Paused)
    _ = bv
    if !bok { return false }
    return true
  }
  return false
}
canTransition_tuck_PlayerState :: proc(frm: tuck_PlayerStateKind, to: tuck_PlayerStateKind) -> bool {
	switch frm {
	case .Idle: return to == .Decoding
	case .Decoding: return to == .Paused || to == .Idle
	case .Paused: return to == .Decoding || to == .Idle
	}
	return false
}
transitionTo_tuck_PlayerState :: proc(self: ^tuck_PlayerState, target: tuck_PlayerState) {
	assert(canTransition_tuck_PlayerState(tag_tuck_PlayerState(self^), tag_tuck_PlayerState(target)), "Invalid transition")
	self^ = target
}

tuck_BufferPool: rt.ObjectPool([512]u8, 4)

tuck_Volume :: struct {
	level: u8,
}
validate_tuck_Volume :: proc(self: tuck_Volume) {
	assert((self.level <= 100))
}
__validated_tuck_Volume :: proc(v: tuck_Volume) -> tuck_Volume {
	validate_tuck_Volume(v)
	return v
}

tuck_streamReader :: proc(streamId: u8, chunks: [dynamic]u32) -> rt.TuckResult(rt.TuckUnit) {
  for tuck_i in chunks {
      tuck_buf := rt.acquire(&tuck_BufferPool)
      if !(tuck_buf.status == .Ok) {
          return rt.tokVoid()
      }
      tuck_DMA1_CH3_EN_set(true)
      rt.release(&tuck_BufferPool, tuck_buf.value)
  }
  return {}
}

tuck_DecoderMsgKind :: enum { msgPlay, msgPause, msgStop }
tuck_DecoderMsg :: struct {
	tuckTag: tuck_DecoderMsgKind,
	rate: tuck_Hz,
}
tuck_Decoder :: struct {
	state: tuck_PlayerState,
	vol: tuck_Volume,
	mailbox: rt.Mailbox(tuck_DecoderMsg, 8),
}

tuck_DecoderSingleton: tuck_Decoder

handleMsg_tuck_Decoder :: proc(self: ^tuck_Decoder, msg: tuck_DecoderMsg) {
	switch msg.tuckTag {
	case .msgPlay:
		rate := msg.rate
    switch v in self.state
    {
    case tuck_PlayerState_Idle:
        self.state = tuck_PlayerState_Decoding{sampleRate = rate}
        raise_tuck_SystemEvents_PlaybackStarted()
        tuck_DAC_CR_EN_set(true)
    case tuck_PlayerState_Paused:
        self.state = tuck_PlayerState_Decoding{sampleRate = rate}
        raise_tuck_SystemEvents_PlaybackStarted()
        tuck_DAC_CR_EN_set(true)
    case tuck_PlayerState_Decoding: ;
    }
	case .msgPause:
    switch v in self.state
    {
    case tuck_PlayerState_Decoding: self.state = tuck_PlayerState_Paused{};
    case tuck_PlayerState_Idle: ;
    case tuck_PlayerState_Paused: ;
    }
    tuck_DAC_CR_EN_set(false)
	case .msgStop:
    self.state = tuck_PlayerState_Idle{}
    raise_tuck_SystemEvents_PlaybackStopped()
    tuck_DAC_CR_EN_set(false)
	}
}

tuck_DecoderSlot: rawptr

drain_tuck_Decoder :: proc() -> bool {
	didWork := false
	batch, n := rt.takeBatch(&tuck_DecoderSingleton.mailbox)
	for i in 0 ..< n {
		handleMsg_tuck_Decoder(&tuck_DecoderSingleton, batch[i])
		rt.tuckCheckWaiters()
		didWork = true
	}
	return didWork
}

sendPlay_tuck_Decoder :: proc(self: ^tuck_Decoder, rate: tuck_Hz) {
	_ = rt.enqueue(&self.mailbox, tuck_DecoderMsg{tuckTag = .msgPlay, rate = rate})
	rt.tuckNotifySend(tuck_DecoderSlot)
}

sendPause_tuck_Decoder :: proc(self: ^tuck_Decoder) {
	_ = rt.enqueue(&self.mailbox, tuck_DecoderMsg{tuckTag = .msgPause})
	rt.tuckNotifySend(tuck_DecoderSlot)
}

sendStop_tuck_Decoder :: proc(self: ^tuck_Decoder) {
	_ = rt.enqueue(&self.mailbox, tuck_DecoderMsg{tuckTag = .msgStop})
	rt.tuckNotifySend(tuck_DecoderSlot)
}

tuck_SystemEvents_PlaybackStarted :: proc () {
  tuck_DAC_CR_EN_set(true)
}

tuck_SystemEvents_PlaybackStopped :: proc () {
  tuck_DAC_CR_EN_set(false)
}

tuck_SystemEvents_HardwareError :: proc (code: u8) {
  tuck_failed := code
  tuck_DAC_CR_EN_set(false)
}

tuck_main :: proc () {

}

main :: proc() {
	assert((size_of(tuck_Volume) == 1))
	rt.tuckAsyncInit()
	tuck_DecoderSlot = rt.tuckStartActor(drain_tuck_Decoder)
	tuck_main()
	rt.tuckRun()
	rt.tuckDrainActors()
}
