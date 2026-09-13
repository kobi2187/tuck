#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"
import scheduler "./mod_scheduler"

tuck_VI_CTRL := cast(^u32)(uintptr(0x50000000))
tuck_VI_CTRL_ENABLE_SHIFT :: 0
tuck_VI_CTRL_FRAME_DONE_SHIFT :: 1
tuck_VI_CTRL_OVERRUN_SHIFT :: 2
tuck_VI_CTRL_ENABLE_get :: proc() -> bool {
	return (tuck_VI_CTRL^ & (u32(1) << u32(tuck_VI_CTRL_ENABLE_SHIFT))) != 0
}
tuck_VI_CTRL_ENABLE_set :: proc(on: bool) {
	mask := u32(1) << u32(tuck_VI_CTRL_ENABLE_SHIFT)
	if on { tuck_VI_CTRL^ |= mask } else { tuck_VI_CTRL^ &~= mask }
}
tuck_VI_CTRL_FRAME_DONE_get :: proc() -> bool {
	return (tuck_VI_CTRL^ & (u32(1) << u32(tuck_VI_CTRL_FRAME_DONE_SHIFT))) != 0
}
tuck_VI_CTRL_OVERRUN_get :: proc() -> bool {
	return (tuck_VI_CTRL^ & (u32(1) << u32(tuck_VI_CTRL_OVERRUN_SHIFT))) != 0
}

tuck_VI_DMA := cast(^u32)(uintptr(0x50000010))
tuck_VI_DMA_ARMED_SHIFT :: 0
tuck_VI_DMA_ARMED_get :: proc() -> bool {
	return (tuck_VI_DMA^ & (u32(1) << u32(tuck_VI_DMA_ARMED_SHIFT))) != 0
}
tuck_VI_DMA_ARMED_set :: proc(on: bool) {
	mask := u32(1) << u32(tuck_VI_DMA_ARMED_SHIFT)
	if on { tuck_VI_DMA^ |= mask } else { tuck_VI_DMA^ &~= mask }
}

tuck_DEC_CTRL := cast(^u32)(uintptr(0x50001000))
tuck_DEC_CTRL_START_SHIFT :: 0
tuck_DEC_CTRL_BUSY_SHIFT :: 1
tuck_DEC_CTRL_ERR_SHIFT :: 2
tuck_DEC_CTRL_START_get :: proc() -> bool {
	return (tuck_DEC_CTRL^ & (u32(1) << u32(tuck_DEC_CTRL_START_SHIFT))) != 0
}
tuck_DEC_CTRL_START_set :: proc(on: bool) {
	mask := u32(1) << u32(tuck_DEC_CTRL_START_SHIFT)
	if on { tuck_DEC_CTRL^ |= mask } else { tuck_DEC_CTRL^ &~= mask }
}
tuck_DEC_CTRL_BUSY_get :: proc() -> bool {
	return (tuck_DEC_CTRL^ & (u32(1) << u32(tuck_DEC_CTRL_BUSY_SHIFT))) != 0
}
tuck_DEC_CTRL_ERR_get :: proc() -> bool {
	return (tuck_DEC_CTRL^ & (u32(1) << u32(tuck_DEC_CTRL_ERR_SHIFT))) != 0
}

tuck_FrameBuffers: rt.ObjectPool([4096]u8, 4)

tuck_NalKind :: enum { nonIdr, idr, sps, pps, sei }

tuck_Action :: enum { decode, configure, skip, flushThenDecode }

tuck_route :: proc(nal: tuck_NalKind, configured: bool, midFrame: bool) -> tuck_Action {
	switch int(nal) * 4 + (configured ? 1 : 0) * 2 + (midFrame ? 1 : 0) {   // packed decision key
	case 0, 1, 16, 17, 18, 19: return tuck_Action.skip
	case 2, 3, 4, 6: return tuck_Action.decode
	case 5, 7: return tuck_Action.flushThenDecode
	case: return tuck_Action.configure
	}
}

tuck_Frame :: struct {
	width: int,
	height: int,
	bytes: int,
}
validate_tuck_Frame :: proc(self: tuck_Frame) {
	assert((self.width > 0))
	assert((self.height > 0))
	assert((self.width <= 1920))
	assert((self.height <= 1080))
	assert((self.bytes <= 4096))
}
__validated_tuck_Frame :: proc(v: tuck_Frame) -> tuck_Frame {
	validate_tuck_Frame(v)
	return v
}

tuck_DecoderState :: enum { Idle, Configured, Decoding, Draining }
canTransition_tuck_DecoderState :: proc(frm: tuck_DecoderState, to: tuck_DecoderState) -> bool {
	switch frm {
	case .Idle: return to == .Configured
	case .Configured: return to == .Decoding
	case .Decoding: return to == .Draining || to == .Configured
	case .Draining: return to == .Decoding || to == .Configured
	}
	return false
}
transitionTo_tuck_DecoderState :: proc(self: ^tuck_DecoderState, target: tuck_DecoderState) {
	assert(canTransition_tuck_DecoderState(self^, target), "Invalid transition")
	self^ = target
}

tuck_VideoKind :: enum { FrameReady, Overrun, DecodeError }
tuck_Video :: struct {
	tuckTag: tuck_VideoKind,
	bytes: int,
	dropped: int,
	code: u8,
}

latesttuck_Video: tuck_Video

raise_tuck_Video_FrameReady :: proc(bytes: int) {
	latesttuck_Video = tuck_Video{tuckTag = .FrameReady, bytes = bytes}
	tuck_Video_FrameReady(bytes)
}

raise_tuck_Video_Overrun :: proc(dropped: int) {
	latesttuck_Video = tuck_Video{tuckTag = .Overrun, dropped = dropped}
	tuck_Video_Overrun(dropped)
}

raise_tuck_Video_DecodeError :: proc(code: u8) {
	latesttuck_Video = tuck_Video{tuckTag = .DecodeError, code = code}
	tuck_Video_DecodeError(code)
}


tuck_PipelineMsgKind :: enum { msgNal, msgOverrun }
tuck_PipelineMsg :: struct {
	tuckTag: tuck_PipelineMsgKind,
	nal: tuck_NalKind,
	midFrame: bool,
	n: int,
}
tuck_Pipeline :: struct {
	state: tuck_DecoderState,
	decoded: int,
	dropped: int,
	configured: bool,
	mailbox: rt.Mailbox(tuck_PipelineMsg, 8),
}

tuck_PipelineSingleton: tuck_Pipeline

handleMsg_tuck_Pipeline :: proc(self: ^tuck_Pipeline, msg: tuck_PipelineMsg) {
	switch msg.tuckTag {
	case .msgNal:
		nal := msg.nal
		midFrame := msg.midFrame
    tuck_what := tuck_route(nal, self.configured, midFrame)
    switch (tuck_what)
    {
    case tuck_Action.configure:
        self.configured = true
        self.state = tuck_DecoderState.Configured
    case tuck_Action.decode:
        self.state = tuck_DecoderState.Decoding
        self.decoded = (self.decoded + 1)
    case tuck_Action.flushThenDecode:
        self.state = tuck_DecoderState.Draining
        self.decoded = (self.decoded + 1)
    case tuck_Action.skip:
        self.dropped = (self.dropped + 1)
    }
	case .msgOverrun:
		n := msg.n
    self.dropped = (self.dropped + n)
	}
}

drain_tuck_Pipeline :: proc() {
	for {
		msg: tuck_PipelineMsg
		for rt.dequeue(&tuck_PipelineSingleton.mailbox, &msg) {
			handleMsg_tuck_Pipeline(&tuck_PipelineSingleton, msg)
		}
		rt.coroYield()
	}
}

sendNal_tuck_Pipeline :: proc(self: ^tuck_Pipeline, nal: tuck_NalKind, midFrame: bool) {
	_ = rt.enqueue(&self.mailbox, tuck_PipelineMsg{tuckTag = .msgNal, nal = nal, midFrame = midFrame})
}

sendOverrun_tuck_Pipeline :: proc(self: ^tuck_Pipeline, n: int) {
	_ = rt.enqueue(&self.mailbox, tuck_PipelineMsg{tuckTag = .msgOverrun, n = n})
}

tuck_capture :: proc (want: int) -> int {
  tuck_slot := rt.acquire(&tuck_FrameBuffers)
  if !(tuck_slot.status == .Ok) {
      raise_tuck_Video_Overrun(1)
      return 0
  }
  tuck_VI_DMA_ARMED_set(true)
  rt.release(&tuck_FrameBuffers, tuck_slot.value)
  return want
}

tuck_Video_FrameReady :: proc (bytes: int) {
  tuck_DEC_CTRL_START_set(true)
}

tuck_Video_Overrun :: proc (dropped: int) {
  tuck_VI_CTRL_ENABLE_set(false)
}

tuck_Video_DecodeError :: proc (code: u8) {
  tuck_VI_CTRL_ENABLE_set(false)
}

tuck_feed :: proc (nal: tuck_NalKind, midFrame: bool) {
  sendNal_tuck_Pipeline(&tuck_PipelineSingleton, nal, midFrame)
  return
}

tuck_drained :: proc () -> bool {
  return ((tuck_PipelineSingleton.decoded + tuck_PipelineSingleton.dropped) >= 5)
}

tuck_config :: proc () {
  tuck_feed(tuck_NalKind.sps, false)
  tuck_feed(tuck_NalKind.pps, false)
  return
}

tuck_stream :: proc () {
  tuck_config()
  tuck_feed(tuck_NalKind.idr, false)
  tuck_feed(tuck_NalKind.nonIdr, false)
  tuck_feed(tuck_NalKind.nonIdr, false)
  tuck_feed(tuck_NalKind.sei, false)
  tuck_feed(tuck_NalKind.idr, true)
  return
}

tuck_main :: proc () -> int {
  tuck_f := __validated_tuck_Frame(tuck_Frame{width = 1920, height = 1080, bytes = 4096})
  tuck_stream()
  scheduler.waitUntil(tuck_drained)
  return ((tuck_PipelineSingleton.decoded * 10) + tuck_PipelineSingleton.dropped)
}

main :: proc() {
	rt.tuckAsyncInit()
	rt.tuckStartActor(drain_tuck_Pipeline)
	mainRc := tuck_main()
	os.exit(mainRc)
}
