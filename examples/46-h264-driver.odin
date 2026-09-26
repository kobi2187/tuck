#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"

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

tuck_type_NalKind :: enum { nonIdr, idr, sps, pps, sei }

tuck_type_Action :: enum { decode, configure, skip, flushThenDecode }

tuck_fn_route :: proc (nal: tuck_type_NalKind, configured: bool, midFrame: bool) -> tuck_type_Action {
  switch ((((int(nal) * 4) + ((configured ? 1 : 0) * 2)) + (midFrame ? 1 : 0)))
  {
  case 0, 1, 16, 17, 18, 19: return tuck_type_Action.skip;
  case 2, 3, 4, 6: return tuck_type_Action.decode;
  case 5, 7: return tuck_type_Action.flushThenDecode;
  case: return tuck_type_Action.configure;
  }
  return {}
}

tuck_type_Frame :: struct {
	width: int,
	height: int,
	bytes: int,
}
validate_tuck_type_Frame :: proc(self: tuck_type_Frame) {
	assert((self.width > 0))
	assert((self.height > 0))
	assert((self.width <= 1920))
	assert((self.height <= 1080))
	assert((self.bytes <= 4096))
}
__validated_tuck_type_Frame :: proc(v: tuck_type_Frame) -> tuck_type_Frame {
	validate_tuck_type_Frame(v)
	return v
}

tuck_type_DecoderState :: enum { Idle, Configured, Decoding, Draining }
canTransition_tuck_type_DecoderState :: proc(frm: tuck_type_DecoderState, to: tuck_type_DecoderState) -> bool {
	switch frm {
	case .Idle: return to == .Configured
	case .Configured: return to == .Decoding
	case .Decoding: return to == .Draining || to == .Configured
	case .Draining: return to == .Decoding || to == .Configured
	}
	return false
}
transitionTo_tuck_type_DecoderState :: proc(self: ^tuck_type_DecoderState, target: tuck_type_DecoderState) {
	assert(canTransition_tuck_type_DecoderState(self^, target), "Invalid transition")
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
	tuck_fn_Video_FrameReady(bytes)
}

raise_tuck_Video_Overrun :: proc(dropped: int) {
	latesttuck_Video = tuck_Video{tuckTag = .Overrun, dropped = dropped}
	tuck_fn_Video_Overrun(dropped)
}

raise_tuck_Video_DecodeError :: proc(code: u8) {
	latesttuck_Video = tuck_Video{tuckTag = .DecodeError, code = code}
	tuck_fn_Video_DecodeError(code)
}


tuck_type_PipelineMsgKind :: enum { msgNal, msgOverrun }
tuck_type_PipelineMsg :: struct {
	tuckTag: tuck_type_PipelineMsgKind,
	nal: tuck_type_NalKind,
	midFrame: bool,
	n: int,
}
tuck_type_Pipeline :: struct {
	state: tuck_type_DecoderState,
	decoded: int,
	dropped: int,
	configured: bool,
	mailbox: rt.Mailbox(tuck_type_PipelineMsg, 8),
}

tuck_type_PipelineSingleton: tuck_type_Pipeline

handleMsg_tuck_type_Pipeline :: proc(self: ^tuck_type_Pipeline, msg: tuck_type_PipelineMsg) {
	switch msg.tuckTag {
	case .msgNal:
		nal := msg.nal
		midFrame := msg.midFrame
    tuck_what := tuck_fn_route(nal, self.configured, midFrame)
    switch (tuck_what)
    {
    case tuck_type_Action.configure:
        self.configured = true
        self.state = tuck_type_DecoderState.Configured
    case tuck_type_Action.decode:
        self.state = tuck_type_DecoderState.Decoding
        self.decoded = (self.decoded + 1)
    case tuck_type_Action.flushThenDecode:
        self.state = tuck_type_DecoderState.Draining
        self.decoded = (self.decoded + 1)
    case tuck_type_Action.skip:
        self.dropped = (self.dropped + 1)
    }
	case .msgOverrun:
		n := msg.n
    self.dropped = (self.dropped + n)
	}
}

tuck_type_PipelineSlot: rawptr

drain_tuck_type_Pipeline :: proc() -> bool {
	didWork := false
	batch, n := rt.takeBatch(&tuck_type_PipelineSingleton.mailbox)
	for i in 0 ..< n {
		handleMsg_tuck_type_Pipeline(&tuck_type_PipelineSingleton, batch[i])
		rt.tuckCheckWaiters()
		didWork = true
	}
	return didWork
}

sendNal_tuck_type_Pipeline :: proc(self: ^tuck_type_Pipeline, nal: tuck_type_NalKind, midFrame: bool) {
	_ = rt.enqueue(&self.mailbox, tuck_type_PipelineMsg{tuckTag = .msgNal, nal = nal, midFrame = midFrame})
	rt.tuckNotifySend(tuck_type_PipelineSlot)
}

sendOverrun_tuck_type_Pipeline :: proc(self: ^tuck_type_Pipeline, n: int) {
	_ = rt.enqueue(&self.mailbox, tuck_type_PipelineMsg{tuckTag = .msgOverrun, n = n})
	rt.tuckNotifySend(tuck_type_PipelineSlot)
}

tuck_fn_capture :: proc (want: int) -> int {
  tuck_slot := rt.acquire(&tuck_FrameBuffers)
  if !(tuck_slot.status == .Ok) {
      raise_tuck_Video_Overrun(1)
      return 0
  }
  tuck_VI_DMA_ARMED_set(true)
  rt.release(&tuck_FrameBuffers, tuck_slot.value)
  return want
}

tuck_fn_Video_FrameReady :: proc (bytes: int) {
  tuck_DEC_CTRL_START_set(true)
}

tuck_fn_Video_Overrun :: proc (dropped: int) {
  tuck_VI_CTRL_ENABLE_set(false)
}

tuck_fn_Video_DecodeError :: proc (code: u8) {
  tuck_VI_CTRL_ENABLE_set(false)
}

tuck_fn_feed :: proc (nal: tuck_type_NalKind, midFrame: bool) {
  sendNal_tuck_type_Pipeline(&tuck_type_PipelineSingleton, nal, midFrame)
  return
}

tuck_fn_drained :: proc () -> bool {
  return ((tuck_type_PipelineSingleton.decoded + tuck_type_PipelineSingleton.dropped) >= 5)
}

tuck_fn_config :: proc () {
  tuck_fn_feed(tuck_type_NalKind.sps, false)
  tuck_fn_feed(tuck_type_NalKind.pps, false)
  return
}

tuck_fn_stream :: proc () {
  tuck_fn_config()
  tuck_fn_feed(tuck_type_NalKind.idr, false)
  tuck_fn_feed(tuck_type_NalKind.nonIdr, false)
  tuck_fn_feed(tuck_type_NalKind.nonIdr, false)
  tuck_fn_feed(tuck_type_NalKind.sei, false)
  tuck_fn_feed(tuck_type_NalKind.idr, true)
  return
}

tuck_fn_main :: proc () -> int {
  tuck_f := __validated_tuck_type_Frame(tuck_type_Frame{width = 1920, height = 1080, bytes = 4096})
  tuck_fn_stream()
  rt.tuckWaitOn(tuck_type_PipelineSlot, tuck_fn_drained)
  return ((tuck_type_PipelineSingleton.decoded * 10) + tuck_type_PipelineSingleton.dropped)
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuck_type_PipelineSingleton.state = tuck_type_DecoderState.Idle
	tuck_type_PipelineSingleton.decoded = 0
	tuck_type_PipelineSingleton.dropped = 0
	tuck_type_PipelineSingleton.configured = false
	rt.tuckAsyncInit()
	tuck_type_PipelineSlot = rt.tuckStartActor(drain_tuck_type_Pipeline)
	mainRc := tuck_fn_main()
	rt.tuckDrainActors()
	rt.tuckTrackCheck()
	os.exit(mainRc)
}
