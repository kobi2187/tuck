{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import scheduler

proc tuckˑdecisionˑroute*(nal: tuckˑtypeˑNalKind, configured: bool, midFrame: bool): tuckˑtypeˑAction
proc tuckˑfnˑcapture*(want: int): int
proc tuckˑfnˑVideo_FrameReady*(bytes: int): void
proc tuckˑfnˑVideo_Overrun*(dropped: int): void
proc tuckˑfnˑVideo_DecodeError*(code: uint8): void
proc tuckˑfnˑfeed*(nal: tuckˑtypeˑNalKind, midFrame: bool): void
proc tuckˑfnˑdrained*(): bool
proc tuckˑfnˑconfig*(): void
proc tuckˑfnˑstream*(): void
proc tuckˑfnˑmain*(): int

type tuckˑtypeˑNalKind* = enum nonIdr, idr, sps, pps, sei

type tuckˑtypeˑAction* = enum decode, configure, skip, flushThenDecode

type tuckˑtypeˑFrame* = object
  width*: int
  height*: int
  bytes*: int

proc validate*(self: tuckˑtypeˑFrame) =
  when not defined(tuckNoInvariants):
    if not ((self.width > 0)): tuckInvariantFailed("(self.width > 0)", "tuckˑtypeˑFrame")
    if not ((self.height > 0)): tuckInvariantFailed("(self.height > 0)", "tuckˑtypeˑFrame")
    if not ((self.width <= 1920)): tuckInvariantFailed("(self.width <= 1920)", "tuckˑtypeˑFrame")
    if not ((self.height <= 1080)): tuckInvariantFailed("(self.height <= 1080)", "tuckˑtypeˑFrame")
    if not ((self.bytes <= 4096)): tuckInvariantFailed("(self.bytes <= 4096)", "tuckˑtypeˑFrame")

type tuckˑtypeˑDecoderState* = enum Idle, Configured, Decoding, Draining
proc canTransition*(frm, to: tuckˑtypeˑDecoderState): bool =
  case frm
  of Idle: to in {Configured}
  of Configured: to in {Decoding}
  of Decoding: to in {Draining, Configured}
  of Draining: to in {Decoding, Configured}
proc transitionTo*(self: var tuckˑtypeˑDecoderState, target: tuckˑtypeˑDecoderState) =
  if not canTransition(self, target):
    raise newException(ValueError, "Invalid transition " & $self & " -> " & $target)
  self = target

var tuckˑregisterˑVI_CTRL = cast[ptr uint32](0x50000000)
const tuckˑregisterˑVI_CTRL_ENABLE_SHIFT = 0
const tuckˑregisterˑVI_CTRL_FRAME_DONE_SHIFT = 1
const tuckˑregisterˑVI_CTRL_OVERRUN_SHIFT = 2
proc tuckˑregisterˑVI_CTRL_ENABLE_get*(): bool {.inline.} =
  (tuckˑregisterˑVI_CTRL[] and (1'u32 shl tuckˑregisterˑVI_CTRL_ENABLE_SHIFT)) != 0
proc tuckˑregisterˑVI_CTRL_ENABLE_set*(value: bool) {.inline.} =
  let mask = 1'u32 shl tuckˑregisterˑVI_CTRL_ENABLE_SHIFT
  if value: tuckˑregisterˑVI_CTRL[] = tuckˑregisterˑVI_CTRL[] or mask
  else: tuckˑregisterˑVI_CTRL[] = tuckˑregisterˑVI_CTRL[] and not mask
proc tuckˑregisterˑVI_CTRL_FRAME_DONE_get*(): bool {.inline.} =
  (tuckˑregisterˑVI_CTRL[] and (1'u32 shl tuckˑregisterˑVI_CTRL_FRAME_DONE_SHIFT)) != 0
proc tuckˑregisterˑVI_CTRL_OVERRUN_get*(): bool {.inline.} =
  (tuckˑregisterˑVI_CTRL[] and (1'u32 shl tuckˑregisterˑVI_CTRL_OVERRUN_SHIFT)) != 0

var tuckˑregisterˑVI_DMA = cast[ptr uint32](0x50000010)
const tuckˑregisterˑVI_DMA_ARMED_SHIFT = 0
proc tuckˑregisterˑVI_DMA_ARMED_get*(): bool {.inline.} =
  (tuckˑregisterˑVI_DMA[] and (1'u32 shl tuckˑregisterˑVI_DMA_ARMED_SHIFT)) != 0
proc tuckˑregisterˑVI_DMA_ARMED_set*(value: bool) {.inline.} =
  let mask = 1'u32 shl tuckˑregisterˑVI_DMA_ARMED_SHIFT
  if value: tuckˑregisterˑVI_DMA[] = tuckˑregisterˑVI_DMA[] or mask
  else: tuckˑregisterˑVI_DMA[] = tuckˑregisterˑVI_DMA[] and not mask

var tuckˑregisterˑDEC_CTRL = cast[ptr uint32](0x50001000)
const tuckˑregisterˑDEC_CTRL_START_SHIFT = 0
const tuckˑregisterˑDEC_CTRL_BUSY_SHIFT = 1
const tuckˑregisterˑDEC_CTRL_ERR_SHIFT = 2
proc tuckˑregisterˑDEC_CTRL_START_get*(): bool {.inline.} =
  (tuckˑregisterˑDEC_CTRL[] and (1'u32 shl tuckˑregisterˑDEC_CTRL_START_SHIFT)) != 0
proc tuckˑregisterˑDEC_CTRL_START_set*(value: bool) {.inline.} =
  let mask = 1'u32 shl tuckˑregisterˑDEC_CTRL_START_SHIFT
  if value: tuckˑregisterˑDEC_CTRL[] = tuckˑregisterˑDEC_CTRL[] or mask
  else: tuckˑregisterˑDEC_CTRL[] = tuckˑregisterˑDEC_CTRL[] and not mask
proc tuckˑregisterˑDEC_CTRL_BUSY_get*(): bool {.inline.} =
  (tuckˑregisterˑDEC_CTRL[] and (1'u32 shl tuckˑregisterˑDEC_CTRL_BUSY_SHIFT)) != 0
proc tuckˑregisterˑDEC_CTRL_ERR_get*(): bool {.inline.} =
  (tuckˑregisterˑDEC_CTRL[] and (1'u32 shl tuckˑregisterˑDEC_CTRL_ERR_SHIFT)) != 0

var tuckˑpoolˑFrameBuffers* = ObjectPool[array[4096, uint8], 4]()
proc tuckˑdecisionˑroute*(nal: tuckˑtypeˑNalKind, configured: bool, midFrame: bool): tuckˑtypeˑAction =
  (case (((ord(nal) * 4) + (ord(configured) * 2)) + ord(midFrame))
  of 0, 1, 16, 17, 18, 19:
    return tuckˑtypeˑAction.skip
  of 2, 3, 4, 6:
    return tuckˑtypeˑAction.decode
  of 5, 7:
    return tuckˑtypeˑAction.flushThenDecode
  else:
    return tuckˑtypeˑAction.configure)

type tuckˑregistryˑVideoKind* = enum FrameReady, Overrun, DecodeError
type tuckˑregistryˑVideo* = ref object
  tuckTag*: tuckˑregistryˑVideoKind
  bytes*: int
  dropped*: int
  code*: uint8

var latesttuckˑregistryˑVideo*: tuckˑregistryˑVideo

proc raise_tuckˑregistryˑVideo_FrameReady*(bytes: int) =
  latesttuckˑregistryˑVideo = tuckˑregistryˑVideo(tuckTag: FrameReady, bytes: bytes)
  tuckˑfnˑVideo_FrameReady(bytes)

proc raise_tuckˑregistryˑVideo_Overrun*(dropped: int) =
  latesttuckˑregistryˑVideo = tuckˑregistryˑVideo(tuckTag: Overrun, dropped: dropped)
  tuckˑfnˑVideo_Overrun(dropped)

proc raise_tuckˑregistryˑVideo_DecodeError*(code: uint8) =
  latesttuckˑregistryˑVideo = tuckˑregistryˑVideo(tuckTag: DecodeError, code: code)
  tuckˑfnˑVideo_DecodeError(code)


type tuckˑactorˑPipelineMsgKind* = enum msgNal, msgOverrun
type tuckˑactorˑPipelineMsg* = object
  tuckTag*: tuckˑactorˑPipelineMsgKind
  nal*: tuckˑtypeˑNalKind
  midFrame*: bool
  n*: int

type tuckˑactorˑPipeline* = ref object
  state*: tuckˑtypeˑDecoderState
  decoded*: int
  dropped*: int
  configured*: bool
  mailbox*: Mailbox[tuckˑactorˑPipelineMsg, 8]

let tuckˑactorˑPipelineSingleton* = tuckˑactorˑPipeline(state: tuckˑtypeˑDecoderState.Idle, decoded: 0, dropped: 0, configured: false)

proc handleMsg*(self: tuckˑactorˑPipeline, msg: tuckˑactorˑPipelineMsg) =
  case msg.tuckTag
  of msgNal:
    let nal = msg.nal
    let midFrame = msg.midFrame
    if true:
      var tuckˑvˑwhat = tuckˑdecisionˑroute(nal, self.configured, midFrame)
      (case tuckˑvˑwhat
      of configure:
        if true:
          self.configured = true
          self.state = tuckˑtypeˑDecoderState.Configured
      of decode:
        if true:
          self.state = tuckˑtypeˑDecoderState.Decoding
          self.decoded = (self.decoded + 1)
      of flushThenDecode:
        if true:
          self.state = tuckˑtypeˑDecoderState.Draining
          self.decoded = (self.decoded + 1)
      of skip:
        if true:
          self.dropped = (self.dropped + 1))
  of msgOverrun:
    let n = msg.n
    if true:
      self.dropped = (self.dropped + n)

proc draintuckˑactorˑPipeline(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    for m in messages(tuckˑactorˑPipelineSingleton.mailbox):
      handleMsg(tuckˑactorˑPipelineSingleton, m)
      tuckCheckWaiters()
      result = true

var tuckˑactorˑPipelineSlot*: pointer
proc registerActortuckˑactorˑPipeline*() =
  tuckˑactorˑPipelineSlot = tuckStartActor(draintuckˑactorˑPipeline)

proc tuckˑfnˑcapture*(want: int): int =
  var tuckˑvˑslot = acquire(tuckˑpoolˑFrameBuffers)
  if not tuckˑvˑslot.ok:
    if true:
      raise_tuckˑregistryˑVideo_Overrun(1)
      return 0
  tuckˑregisterˑVI_DMA_ARMED_set(true)
  release(tuckˑpoolˑFrameBuffers, tuckˑvˑslot.value)
  return want

proc tuckˑfnˑVideo_FrameReady*(bytes: int): void =
  tuckˑregisterˑDEC_CTRL_START_set(true)

proc tuckˑfnˑVideo_Overrun*(dropped: int): void =
  tuckˑregisterˑVI_CTRL_ENABLE_set(false)

proc tuckˑfnˑVideo_DecodeError*(code: uint8): void =
  tuckˑregisterˑVI_CTRL_ENABLE_set(false)

proc tuckˑfnˑfeed*(nal: tuckˑtypeˑNalKind, midFrame: bool): void =
  discard enqueue(tuckˑactorˑPipelineSingleton.mailbox, tuckˑactorˑPipelineMsg(tuckTag: msgNal, nal: nal, midFrame: midFrame))
  tuckNotifySend(tuckˑactorˑPipelineSlot)
  return

proc tuckˑfnˑdrained*(): bool =
  return ((tuckˑactorˑPipelineSingleton.decoded + tuckˑactorˑPipelineSingleton.dropped) >= 5)

proc tuckˑfnˑconfig*(): void =
  tuckˑfnˑfeed(tuckˑtypeˑNalKind.sps, false)
  tuckˑfnˑfeed(tuckˑtypeˑNalKind.pps, false)
  return

proc tuckˑfnˑstream*(): void =
  tuckˑfnˑconfig()
  tuckˑfnˑfeed(tuckˑtypeˑNalKind.idr, false)
  tuckˑfnˑfeed(tuckˑtypeˑNalKind.nonIdr, false)
  tuckˑfnˑfeed(tuckˑtypeˑNalKind.nonIdr, false)
  tuckˑfnˑfeed(tuckˑtypeˑNalKind.sei, false)
  tuckˑfnˑfeed(tuckˑtypeˑNalKind.idr, true)
  return

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑf = (let tuckInv1 = tuckˑtypeˑFrame(width: 1920, height: 1080, bytes: 4096); validate(tuckInv1); tuckInv1)
  tuckˑfnˑstream()
  tuckWaitOn(tuckˑactorˑPipelineSlot, tuckˑfnˑdrained)
  return ((tuckˑactorˑPipelineSingleton.decoded * 10) + tuckˑactorˑPipelineSingleton.dropped)

