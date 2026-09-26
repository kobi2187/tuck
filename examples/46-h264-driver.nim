{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import scheduler

proc tuck_fn_route*(nal: tuck_type_NalKind, configured: bool, midFrame: bool): tuck_type_Action
proc tuck_fn_capture*(want: int): int
proc tuck_fn_Video_FrameReady*(bytes: int): void
proc tuck_fn_Video_Overrun*(dropped: int): void
proc tuck_fn_Video_DecodeError*(code: uint8): void
proc tuck_fn_feed*(nal: tuck_type_NalKind, midFrame: bool): void
proc tuck_fn_drained*(): bool
proc tuck_fn_config*(): void
proc tuck_fn_stream*(): void
proc tuck_fn_main*(): int

type tuck_type_NalKind* = enum nonIdr, idr, sps, pps, sei

type tuck_type_Action* = enum decode, configure, skip, flushThenDecode

type tuck_type_Frame* = object
  width*: int
  height*: int
  bytes*: int

proc validate*(self: tuck_type_Frame) =
  when not defined(tuckNoInvariants):
    if not ((self.width > 0)): tuckInvariantFailed("(self.width > 0)", "tuck_type_Frame")
    if not ((self.height > 0)): tuckInvariantFailed("(self.height > 0)", "tuck_type_Frame")
    if not ((self.width <= 1920)): tuckInvariantFailed("(self.width <= 1920)", "tuck_type_Frame")
    if not ((self.height <= 1080)): tuckInvariantFailed("(self.height <= 1080)", "tuck_type_Frame")
    if not ((self.bytes <= 4096)): tuckInvariantFailed("(self.bytes <= 4096)", "tuck_type_Frame")

type tuck_type_DecoderState* = enum Idle, Configured, Decoding, Draining
proc canTransition*(frm, to: tuck_type_DecoderState): bool =
  case frm
  of Idle: to in {Configured}
  of Configured: to in {Decoding}
  of Decoding: to in {Draining, Configured}
  of Draining: to in {Decoding, Configured}
proc transitionTo*(self: var tuck_type_DecoderState, target: tuck_type_DecoderState) =
  if not canTransition(self, target):
    raise newException(ValueError, "Invalid transition " & $self & " -> " & $target)
  self = target

var tuck_VI_CTRL = cast[ptr uint32](0x50000000)
const tuck_VI_CTRL_ENABLE_SHIFT = 0
const tuck_VI_CTRL_FRAME_DONE_SHIFT = 1
const tuck_VI_CTRL_OVERRUN_SHIFT = 2
proc tuck_VI_CTRL_ENABLE_get*(): bool {.inline.} =
  (tuck_VI_CTRL[] and (1'u32 shl tuck_VI_CTRL_ENABLE_SHIFT)) != 0
proc tuck_VI_CTRL_ENABLE_set*(value: bool) {.inline.} =
  let mask = 1'u32 shl tuck_VI_CTRL_ENABLE_SHIFT
  if value: tuck_VI_CTRL[] = tuck_VI_CTRL[] or mask
  else: tuck_VI_CTRL[] = tuck_VI_CTRL[] and not mask
proc tuck_VI_CTRL_FRAME_DONE_get*(): bool {.inline.} =
  (tuck_VI_CTRL[] and (1'u32 shl tuck_VI_CTRL_FRAME_DONE_SHIFT)) != 0
proc tuck_VI_CTRL_OVERRUN_get*(): bool {.inline.} =
  (tuck_VI_CTRL[] and (1'u32 shl tuck_VI_CTRL_OVERRUN_SHIFT)) != 0

var tuck_VI_DMA = cast[ptr uint32](0x50000010)
const tuck_VI_DMA_ARMED_SHIFT = 0
proc tuck_VI_DMA_ARMED_get*(): bool {.inline.} =
  (tuck_VI_DMA[] and (1'u32 shl tuck_VI_DMA_ARMED_SHIFT)) != 0
proc tuck_VI_DMA_ARMED_set*(value: bool) {.inline.} =
  let mask = 1'u32 shl tuck_VI_DMA_ARMED_SHIFT
  if value: tuck_VI_DMA[] = tuck_VI_DMA[] or mask
  else: tuck_VI_DMA[] = tuck_VI_DMA[] and not mask

var tuck_DEC_CTRL = cast[ptr uint32](0x50001000)
const tuck_DEC_CTRL_START_SHIFT = 0
const tuck_DEC_CTRL_BUSY_SHIFT = 1
const tuck_DEC_CTRL_ERR_SHIFT = 2
proc tuck_DEC_CTRL_START_get*(): bool {.inline.} =
  (tuck_DEC_CTRL[] and (1'u32 shl tuck_DEC_CTRL_START_SHIFT)) != 0
proc tuck_DEC_CTRL_START_set*(value: bool) {.inline.} =
  let mask = 1'u32 shl tuck_DEC_CTRL_START_SHIFT
  if value: tuck_DEC_CTRL[] = tuck_DEC_CTRL[] or mask
  else: tuck_DEC_CTRL[] = tuck_DEC_CTRL[] and not mask
proc tuck_DEC_CTRL_BUSY_get*(): bool {.inline.} =
  (tuck_DEC_CTRL[] and (1'u32 shl tuck_DEC_CTRL_BUSY_SHIFT)) != 0
proc tuck_DEC_CTRL_ERR_get*(): bool {.inline.} =
  (tuck_DEC_CTRL[] and (1'u32 shl tuck_DEC_CTRL_ERR_SHIFT)) != 0

var tuck_FrameBuffers* = ObjectPool[array[4096, uint8], 4]()
proc tuck_fn_route*(nal: tuck_type_NalKind, configured: bool, midFrame: bool): tuck_type_Action =
  (case (((ord(nal) * 4) + (ord(configured) * 2)) + ord(midFrame))
  of 0, 1, 16, 17, 18, 19:
    return tuck_type_Action.skip
  of 2, 3, 4, 6:
    return tuck_type_Action.decode
  of 5, 7:
    return tuck_type_Action.flushThenDecode
  else:
    return tuck_type_Action.configure)

type tuck_VideoKind* = enum FrameReady, Overrun, DecodeError
type tuck_Video* = ref object
  tuckTag*: tuck_VideoKind
  bytes*: int
  dropped*: int
  code*: uint8

var latesttuck_Video*: tuck_Video

proc raise_tuck_Video_FrameReady*(bytes: int) =
  latesttuck_Video = tuck_Video(tuckTag: FrameReady, bytes: bytes)
  tuck_fn_Video_FrameReady(bytes)

proc raise_tuck_Video_Overrun*(dropped: int) =
  latesttuck_Video = tuck_Video(tuckTag: Overrun, dropped: dropped)
  tuck_fn_Video_Overrun(dropped)

proc raise_tuck_Video_DecodeError*(code: uint8) =
  latesttuck_Video = tuck_Video(tuckTag: DecodeError, code: code)
  tuck_fn_Video_DecodeError(code)


type tuck_type_PipelineMsgKind* = enum msgNal, msgOverrun
type tuck_type_PipelineMsg* = object
  tuckTag*: tuck_type_PipelineMsgKind
  nal*: tuck_type_NalKind
  midFrame*: bool
  n*: int

type tuck_type_Pipeline* = ref object
  state*: tuck_type_DecoderState
  decoded*: int
  dropped*: int
  configured*: bool
  mailbox*: Mailbox[tuck_type_PipelineMsg, 8]

let tuck_type_PipelineSingleton* = tuck_type_Pipeline(state: tuck_type_DecoderState.Idle, decoded: 0, dropped: 0, configured: false)

proc handleMsg*(self: tuck_type_Pipeline, msg: tuck_type_PipelineMsg) =
  case msg.tuckTag
  of msgNal:
    let nal = msg.nal
    let midFrame = msg.midFrame
    if true:
      var tuck_what = tuck_fn_route(nal, self.configured, midFrame)
      (case tuck_what
      of configure:
        if true:
          self.configured = true
          self.state = tuck_type_DecoderState.Configured
      of decode:
        if true:
          self.state = tuck_type_DecoderState.Decoding
          self.decoded = (self.decoded + 1)
      of flushThenDecode:
        if true:
          self.state = tuck_type_DecoderState.Draining
          self.decoded = (self.decoded + 1)
      of skip:
        if true:
          self.dropped = (self.dropped + 1))
  of msgOverrun:
    let n = msg.n
    if true:
      self.dropped = (self.dropped + n)

proc draintuck_type_Pipeline(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    for m in messages(tuck_type_PipelineSingleton.mailbox):
      handleMsg(tuck_type_PipelineSingleton, m)
      tuckCheckWaiters()
      result = true

var tuck_type_PipelineSlot*: pointer
proc registerActortuck_type_Pipeline*() =
  tuck_type_PipelineSlot = tuckStartActor(draintuck_type_Pipeline)

proc tuck_fn_capture*(want: int): int =
  var tuck_slot = acquire(tuck_FrameBuffers)
  if not tuck_slot.ok:
    if true:
      raise_tuck_Video_Overrun(1)
      return 0
  tuck_VI_DMA_ARMED_set(true)
  release(tuck_FrameBuffers, tuck_slot.value)
  return want

proc tuck_fn_Video_FrameReady*(bytes: int): void =
  tuck_DEC_CTRL_START_set(true)

proc tuck_fn_Video_Overrun*(dropped: int): void =
  tuck_VI_CTRL_ENABLE_set(false)

proc tuck_fn_Video_DecodeError*(code: uint8): void =
  tuck_VI_CTRL_ENABLE_set(false)

proc tuck_fn_feed*(nal: tuck_type_NalKind, midFrame: bool): void =
  discard enqueue(tuck_type_PipelineSingleton.mailbox, tuck_type_PipelineMsg(tuckTag: msgNal, nal: nal, midFrame: midFrame))
  tuckNotifySend(tuck_type_PipelineSlot)
  return

proc tuck_fn_drained*(): bool =
  return ((tuck_type_PipelineSingleton.decoded + tuck_type_PipelineSingleton.dropped) >= 5)

proc tuck_fn_config*(): void =
  tuck_fn_feed(tuck_type_NalKind.sps, false)
  tuck_fn_feed(tuck_type_NalKind.pps, false)
  return

proc tuck_fn_stream*(): void =
  tuck_fn_config()
  tuck_fn_feed(tuck_type_NalKind.idr, false)
  tuck_fn_feed(tuck_type_NalKind.nonIdr, false)
  tuck_fn_feed(tuck_type_NalKind.nonIdr, false)
  tuck_fn_feed(tuck_type_NalKind.sei, false)
  tuck_fn_feed(tuck_type_NalKind.idr, true)
  return

proc tuck_fn_main*(): int =
  var tuck_f = (let tuckInv1 = tuck_type_Frame(width: 1920, height: 1080, bytes: 4096); validate(tuckInv1); tuckInv1)
  tuck_fn_stream()
  tuckWaitOn(tuck_type_PipelineSlot, tuck_fn_drained)
  return ((tuck_type_PipelineSingleton.decoded * 10) + tuck_type_PipelineSingleton.dropped)

