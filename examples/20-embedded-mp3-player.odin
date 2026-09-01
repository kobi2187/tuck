package main

import rt "./tuckrt"

tuck_Hz :: distinct u32

tuck_Milliseconds :: distinct u32

tuck_SystemEventsKind :: enum { PlaybackStarted, PlaybackStopped, HardwareError }
tuck_SystemEvents :: struct {
	kind: tuck_SystemEventsKind,
	code: u8,
}

latesttuck_SystemEvents: tuck_SystemEvents

raise_tuck_SystemEvents_PlaybackStarted :: proc() {
	latesttuck_SystemEvents = tuck_SystemEvents{kind = .PlaybackStarted}
	tuck_SystemEvents_PlaybackStarted()
}

raise_tuck_SystemEvents_PlaybackStopped :: proc() {
	latesttuck_SystemEvents = tuck_SystemEvents{kind = .PlaybackStopped}
	tuck_SystemEvents_PlaybackStopped()
}

raise_tuck_SystemEvents_HardwareError :: proc(code: u8) {
	latesttuck_SystemEvents = tuck_SystemEvents{kind = .HardwareError, code = code}
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
  for i in chunks {
      buf := rt.acquire(&tuck_BufferPool)
      if !(buf.status == .Ok) {
          return rt.tokVoid()
      }
      tuck_DMA1_CH3.EN = true
      rt.release(&tuck_BufferPool, buf.value)
  }
  return {}
}

tuck_DecoderMsgKind :: enum { msgPlay, msgPause, msgStop }
tuck_DecoderMsg :: struct {
	kind: tuck_DecoderMsgKind,
	rate: tuck_Hz,
}
tuck_Decoder :: struct {
	state: tuck_PlayerState,
	vol: tuck_Volume,
	mailbox: rt.Mailbox(tuck_DecoderMsg, 8),
}

tuck_DecoderSingleton: tuck_Decoder

handleMsg_tuck_Decoder :: proc(self: ^tuck_Decoder, msg: tuck_DecoderMsg) {
	switch msg.kind {
	case .msgPlay:
		rate := msg.rate
    switch v in self.state
    {
    case tuck_PlayerState_Idle:
        self.state = tuck_PlayerState_Decoding{sampleRate = rate}
        PlaybackStarted(tuck_SystemEvents.raise)
        tuck_DAC_CR.EN = true
    case tuck_PlayerState_Paused:
        self.state = tuck_PlayerState_Decoding{sampleRate = rate}
        PlaybackStarted(tuck_SystemEvents.raise)
        tuck_DAC_CR.EN = true
    case tuck_PlayerState_Decoding: ;
    }
	case .msgPause:
    switch v in self.state
    {
    case tuck_PlayerState_Decoding: self.state = tuck_PlayerState_Paused{};
    case tuck_PlayerState_Idle: ;
    case tuck_PlayerState_Paused: ;
    }
    tuck_DAC_CR.EN = false
	case .msgStop:
    self.state = tuck_PlayerState_Idle{}
    PlaybackStopped(tuck_SystemEvents.raise)
    tuck_DAC_CR.EN = false
	}
}

drain_tuck_Decoder :: proc() {
	for {
		msg: tuck_DecoderMsg
		for rt.dequeue(&tuck_DecoderSingleton.mailbox, &msg) {
			handleMsg_tuck_Decoder(&tuck_DecoderSingleton, msg)
		}
		rt.coroYield()
	}
}

sendPlay_tuck_Decoder :: proc(self: ^tuck_Decoder, rate: tuck_Hz) {
	_ = rt.enqueue(&self.mailbox, tuck_DecoderMsg{kind = .msgPlay, rate = rate})
}

sendPause_tuck_Decoder :: proc(self: ^tuck_Decoder) {
	_ = rt.enqueue(&self.mailbox, tuck_DecoderMsg{kind = .msgPause})
}

sendStop_tuck_Decoder :: proc(self: ^tuck_Decoder) {
	_ = rt.enqueue(&self.mailbox, tuck_DecoderMsg{kind = .msgStop})
}

tuck_SystemEvents_PlaybackStarted :: proc () {
  tuck_DAC_CR.EN = true
}

tuck_SystemEvents_PlaybackStopped :: proc () {
  tuck_DAC_CR.EN = false
}

tuck_SystemEvents_HardwareError :: proc (code: u8) {
  failed := code
  tuck_DAC_CR.EN = false
}

tuck_main :: proc () {

}

main :: proc() {
	assert((size_of(tuck_Volume) == 1))
	rt.tuckAsyncInit()
	rt.tuckStartActor(drain_tuck_Decoder)
	tuck_main()
	rt.tuckRun()
}
