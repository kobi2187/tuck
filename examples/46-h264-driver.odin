#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"

tuckˑregisterˑVI_CTRL := cast(^u32)(uintptr(0x50000000))
tuckˑregisterˑVI_CTRL_ENABLE_SHIFT :: 0
tuckˑregisterˑVI_CTRL_FRAME_DONE_SHIFT :: 1
tuckˑregisterˑVI_CTRL_OVERRUN_SHIFT :: 2
tuckˑregisterˑVI_CTRL_ENABLE_get :: proc() -> bool {
	return (tuckˑregisterˑVI_CTRL^ & (u32(1) << u32(tuckˑregisterˑVI_CTRL_ENABLE_SHIFT))) != 0
}
tuckˑregisterˑVI_CTRL_ENABLE_set :: proc(on: bool) {
	mask := u32(1) << u32(tuckˑregisterˑVI_CTRL_ENABLE_SHIFT)
	if on { tuckˑregisterˑVI_CTRL^ |= mask } else { tuckˑregisterˑVI_CTRL^ &~= mask }
}
tuckˑregisterˑVI_CTRL_FRAME_DONE_get :: proc() -> bool {
	return (tuckˑregisterˑVI_CTRL^ & (u32(1) << u32(tuckˑregisterˑVI_CTRL_FRAME_DONE_SHIFT))) != 0
}
tuckˑregisterˑVI_CTRL_OVERRUN_get :: proc() -> bool {
	return (tuckˑregisterˑVI_CTRL^ & (u32(1) << u32(tuckˑregisterˑVI_CTRL_OVERRUN_SHIFT))) != 0
}

tuckˑregisterˑVI_DMA := cast(^u32)(uintptr(0x50000010))
tuckˑregisterˑVI_DMA_ARMED_SHIFT :: 0
tuckˑregisterˑVI_DMA_ARMED_get :: proc() -> bool {
	return (tuckˑregisterˑVI_DMA^ & (u32(1) << u32(tuckˑregisterˑVI_DMA_ARMED_SHIFT))) != 0
}
tuckˑregisterˑVI_DMA_ARMED_set :: proc(on: bool) {
	mask := u32(1) << u32(tuckˑregisterˑVI_DMA_ARMED_SHIFT)
	if on { tuckˑregisterˑVI_DMA^ |= mask } else { tuckˑregisterˑVI_DMA^ &~= mask }
}

tuckˑregisterˑDEC_CTRL := cast(^u32)(uintptr(0x50001000))
tuckˑregisterˑDEC_CTRL_START_SHIFT :: 0
tuckˑregisterˑDEC_CTRL_BUSY_SHIFT :: 1
tuckˑregisterˑDEC_CTRL_ERR_SHIFT :: 2
tuckˑregisterˑDEC_CTRL_START_get :: proc() -> bool {
	return (tuckˑregisterˑDEC_CTRL^ & (u32(1) << u32(tuckˑregisterˑDEC_CTRL_START_SHIFT))) != 0
}
tuckˑregisterˑDEC_CTRL_START_set :: proc(on: bool) {
	mask := u32(1) << u32(tuckˑregisterˑDEC_CTRL_START_SHIFT)
	if on { tuckˑregisterˑDEC_CTRL^ |= mask } else { tuckˑregisterˑDEC_CTRL^ &~= mask }
}
tuckˑregisterˑDEC_CTRL_BUSY_get :: proc() -> bool {
	return (tuckˑregisterˑDEC_CTRL^ & (u32(1) << u32(tuckˑregisterˑDEC_CTRL_BUSY_SHIFT))) != 0
}
tuckˑregisterˑDEC_CTRL_ERR_get :: proc() -> bool {
	return (tuckˑregisterˑDEC_CTRL^ & (u32(1) << u32(tuckˑregisterˑDEC_CTRL_ERR_SHIFT))) != 0
}

tuckˑpoolˑFrameBuffers: rt.ObjectPool([4096]u8, 4)

tuckˑtypeˑNalKind :: enum { nonIdr, idr, sps, pps, sei }

tuckˑtypeˑAction :: enum { decode, configure, skip, flushThenDecode }

tuckˑdecisionˑroute :: proc (nal: tuckˑtypeˑNalKind, configured: bool, midFrame: bool) -> tuckˑtypeˑAction {
  switch ((((int(nal) * 4) + ((configured ? 1 : 0) * 2)) + (midFrame ? 1 : 0)))
  {
  case 0, 1, 16, 17, 18, 19: return tuckˑtypeˑAction.skip;
  case 2, 3, 4, 6: return tuckˑtypeˑAction.decode;
  case 5, 7: return tuckˑtypeˑAction.flushThenDecode;
  case: return tuckˑtypeˑAction.configure;
  }
  return {}
}

tuckˑtypeˑFrame :: struct {
	width: int,
	height: int,
	bytes: int,
}
validate_tuckˑtypeˑFrame :: proc(self: tuckˑtypeˑFrame) {
	assert((self.width > 0))
	assert((self.height > 0))
	assert((self.width <= 1920))
	assert((self.height <= 1080))
	assert((self.bytes <= 4096))
}
__validated_tuckˑtypeˑFrame :: proc(v: tuckˑtypeˑFrame) -> tuckˑtypeˑFrame {
	validate_tuckˑtypeˑFrame(v)
	return v
}

tuckˑtypeˑDecoderState :: enum { Idle, Configured, Decoding, Draining }
canTransition_tuckˑtypeˑDecoderState :: proc(frm: tuckˑtypeˑDecoderState, to: tuckˑtypeˑDecoderState) -> bool {
	switch frm {
	case .Idle: return to == .Configured
	case .Configured: return to == .Decoding
	case .Decoding: return to == .Draining || to == .Configured
	case .Draining: return to == .Decoding || to == .Configured
	}
	return false
}
transitionTo_tuckˑtypeˑDecoderState :: proc(self: ^tuckˑtypeˑDecoderState, target: tuckˑtypeˑDecoderState) {
	assert(canTransition_tuckˑtypeˑDecoderState(self^, target), "Invalid transition")
	self^ = target
}

tuckˑregistryˑVideoKind :: enum { FrameReady, Overrun, DecodeError }
tuckˑregistryˑVideo :: struct {
	tuckTag: tuckˑregistryˑVideoKind,
	bytes: int,
	dropped: int,
	code: u8,
}

latesttuckˑregistryˑVideo: tuckˑregistryˑVideo

raise_tuckˑregistryˑVideo_FrameReady :: proc(bytes: int) {
	latesttuckˑregistryˑVideo = tuckˑregistryˑVideo{tuckTag = .FrameReady, bytes = bytes}
	tuckˑfnˑVideo_FrameReady(bytes)
}

raise_tuckˑregistryˑVideo_Overrun :: proc(dropped: int) {
	latesttuckˑregistryˑVideo = tuckˑregistryˑVideo{tuckTag = .Overrun, dropped = dropped}
	tuckˑfnˑVideo_Overrun(dropped)
}

raise_tuckˑregistryˑVideo_DecodeError :: proc(code: u8) {
	latesttuckˑregistryˑVideo = tuckˑregistryˑVideo{tuckTag = .DecodeError, code = code}
	tuckˑfnˑVideo_DecodeError(code)
}


tuckˑactorˑPipelineMsgKind :: enum { msgNal, msgOverrun }
tuckˑactorˑPipelineMsg :: struct {
	tuckTag: tuckˑactorˑPipelineMsgKind,
	nal: tuckˑtypeˑNalKind,
	midFrame: bool,
	n: int,
}
tuckˑactorˑPipeline :: struct {
	state: tuckˑtypeˑDecoderState,
	decoded: int,
	dropped: int,
	configured: bool,
	mailbox: rt.Mailbox(tuckˑactorˑPipelineMsg, 8),
}

tuckˑactorˑPipelineSingleton: tuckˑactorˑPipeline

handleMsg_tuckˑactorˑPipeline :: proc(self: ^tuckˑactorˑPipeline, msg: tuckˑactorˑPipelineMsg) {
	switch msg.tuckTag {
	case .msgNal:
		nal := msg.nal
		midFrame := msg.midFrame
    tuckˑvˑwhat := tuckˑdecisionˑroute(nal, self.configured, midFrame)
    switch (tuckˑvˑwhat)
    {
    case tuckˑtypeˑAction.configure:
        self.configured = true
        self.state = tuckˑtypeˑDecoderState.Configured
    case tuckˑtypeˑAction.decode:
        self.state = tuckˑtypeˑDecoderState.Decoding
        self.decoded = (self.decoded + 1)
    case tuckˑtypeˑAction.flushThenDecode:
        self.state = tuckˑtypeˑDecoderState.Draining
        self.decoded = (self.decoded + 1)
    case tuckˑtypeˑAction.skip:
        self.dropped = (self.dropped + 1)
    }
	case .msgOverrun:
		n := msg.n
    self.dropped = (self.dropped + n)
	}
}

tuckˑactorˑPipelineSlot: rawptr

drain_tuckˑactorˑPipeline :: proc() -> bool {
	didWork := false
	batch, n := rt.takeBatch(&tuckˑactorˑPipelineSingleton.mailbox)
	for i in 0 ..< n {
		handleMsg_tuckˑactorˑPipeline(&tuckˑactorˑPipelineSingleton, batch[i])
		rt.tuckCheckWaiters()
		didWork = true
	}
	return didWork
}

sendNal_tuckˑactorˑPipeline :: proc(self: ^tuckˑactorˑPipeline, nal: tuckˑtypeˑNalKind, midFrame: bool) {
	_ = rt.enqueue(&self.mailbox, tuckˑactorˑPipelineMsg{tuckTag = .msgNal, nal = nal, midFrame = midFrame})
	rt.tuckNotifySend(tuckˑactorˑPipelineSlot)
}

sendOverrun_tuckˑactorˑPipeline :: proc(self: ^tuckˑactorˑPipeline, n: int) {
	_ = rt.enqueue(&self.mailbox, tuckˑactorˑPipelineMsg{tuckTag = .msgOverrun, n = n})
	rt.tuckNotifySend(tuckˑactorˑPipelineSlot)
}

tuckˑfnˑcapture :: proc (want: int) -> int {
  tuckˑvˑslot := rt.tuckPoolAcquire(&tuckˑpoolˑFrameBuffers)
  if !(tuckˑvˑslot.status == .Ok) {
      raise_tuckˑregistryˑVideo_Overrun(1)
      return 0
  }
  tuckˑregisterˑVI_DMA_ARMED_set(true)
  rt.tuckPoolRelease(&tuckˑpoolˑFrameBuffers, tuckˑvˑslot.value)
  return want
}

tuckˑfnˑVideo_FrameReady :: proc (bytes: int) {
  tuckˑregisterˑDEC_CTRL_START_set(true)
}

tuckˑfnˑVideo_Overrun :: proc (dropped: int) {
  tuckˑregisterˑVI_CTRL_ENABLE_set(false)
}

tuckˑfnˑVideo_DecodeError :: proc (code: u8) {
  tuckˑregisterˑVI_CTRL_ENABLE_set(false)
}

tuckˑfnˑfeed :: proc (nal: tuckˑtypeˑNalKind, midFrame: bool) {
  sendNal_tuckˑactorˑPipeline(&tuckˑactorˑPipelineSingleton, nal, midFrame)
  return
}

tuckˑfnˑdrained :: proc () -> bool {
  return ((tuckˑactorˑPipelineSingleton.decoded + tuckˑactorˑPipelineSingleton.dropped) >= 5)
}

tuckˑfnˑconfig :: proc () {
  tuckˑfnˑfeed(tuckˑtypeˑNalKind.sps, false)
  tuckˑfnˑfeed(tuckˑtypeˑNalKind.pps, false)
  return
}

tuckˑfnˑstream :: proc () {
  tuckˑfnˑconfig()
  tuckˑfnˑfeed(tuckˑtypeˑNalKind.idr, false)
  tuckˑfnˑfeed(tuckˑtypeˑNalKind.nonIdr, false)
  tuckˑfnˑfeed(tuckˑtypeˑNalKind.nonIdr, false)
  tuckˑfnˑfeed(tuckˑtypeˑNalKind.sei, false)
  tuckˑfnˑfeed(tuckˑtypeˑNalKind.idr, true)
  return
}

tuckˑfnˑmain :: proc () -> int {
  tuckˑvˑf := __validated_tuckˑtypeˑFrame(tuckˑtypeˑFrame{width = 1920, height = 1080, bytes = 4096})
  tuckˑfnˑstream()
  rt.tuckWaitOn(tuckˑactorˑPipelineSlot, tuckˑfnˑdrained)
  return ((tuckˑactorˑPipelineSingleton.decoded * 10) + tuckˑactorˑPipelineSingleton.dropped)
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuckˑactorˑPipelineSingleton.state = tuckˑtypeˑDecoderState.Idle
	tuckˑactorˑPipelineSingleton.decoded = 0
	tuckˑactorˑPipelineSingleton.dropped = 0
	tuckˑactorˑPipelineSingleton.configured = false
	rt.tuckAsyncInit()
	tuckˑactorˑPipelineSlot = rt.tuckStartActor(drain_tuckˑactorˑPipeline)
	mainRc := tuckˑfnˑmain()
	rt.tuckDrainActors()
	rt.tuckTrackCheck()
	os.exit(mainRc)
}
