{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc `==`*(a, b: tuckˑtypeˑPlayerState): bool {.noSideEffect.}

proc tuckˑfnˑSystemEvents_PlaybackStarted*(): void
proc tuckˑfnˑSystemEvents_PlaybackStopped*(): void
proc tuckˑfnˑSystemEvents_HardwareError*(code: uint8): void
proc tuckˑfnˑmain*(): void

type tuckˑtypeˑHz* = distinct uint32
proc `+`*(a, b: tuckˑtypeˑHz): tuckˑtypeˑHz {.borrow.}
proc `-`*(a, b: tuckˑtypeˑHz): tuckˑtypeˑHz {.borrow.}
proc `*`*(a, b: tuckˑtypeˑHz): tuckˑtypeˑHz {.borrow.}
proc `div`*(a, b: tuckˑtypeˑHz): tuckˑtypeˑHz {.borrow.}
proc `mod`*(a, b: tuckˑtypeˑHz): tuckˑtypeˑHz {.borrow.}
proc `==`*(a, b: tuckˑtypeˑHz): bool {.borrow.}
proc `<`*(a, b: tuckˑtypeˑHz): bool {.borrow.}
proc `<=`*(a, b: tuckˑtypeˑHz): bool {.borrow.}
proc `$`*(a: tuckˑtypeˑHz): string {.borrow.}

type tuckˑtypeˑMilliseconds* = distinct uint32
proc `+`*(a, b: tuckˑtypeˑMilliseconds): tuckˑtypeˑMilliseconds {.borrow.}
proc `-`*(a, b: tuckˑtypeˑMilliseconds): tuckˑtypeˑMilliseconds {.borrow.}
proc `*`*(a, b: tuckˑtypeˑMilliseconds): tuckˑtypeˑMilliseconds {.borrow.}
proc `div`*(a, b: tuckˑtypeˑMilliseconds): tuckˑtypeˑMilliseconds {.borrow.}
proc `mod`*(a, b: tuckˑtypeˑMilliseconds): tuckˑtypeˑMilliseconds {.borrow.}
proc `==`*(a, b: tuckˑtypeˑMilliseconds): bool {.borrow.}
proc `<`*(a, b: tuckˑtypeˑMilliseconds): bool {.borrow.}
proc `<=`*(a, b: tuckˑtypeˑMilliseconds): bool {.borrow.}
proc `$`*(a: tuckˑtypeˑMilliseconds): string {.borrow.}

type tuckˑtypeˑPlayerStateKind* = enum Idle, Decoding, Paused
type tuckˑtypeˑPlayerState* = object
  case kind*: tuckˑtypeˑPlayerStateKind
  of Idle: discard
  of Decoding: tuckˑvariantˑdecoding*: tuple[sampleRate: tuckˑtypeˑHz]
  of Paused: discard

proc `==`*(a, b: tuckˑtypeˑPlayerState): bool {.noSideEffect.} =
  if a.kind != b.kind: return false
  case a.kind
  of Idle: true
  of Decoding: a.tuckˑvariantˑdecoding == b.tuckˑvariantˑdecoding
  of Paused: true
proc canTransition*(frm, to: tuckˑtypeˑPlayerStateKind): bool =
  case frm
  of Idle: to in {Decoding}
  of Decoding: to in {Paused, Idle}
  of Paused: to in {Decoding, Idle}
proc transitionTo*(self: var tuckˑtypeˑPlayerState, target: tuckˑtypeˑPlayerState) =
  if not canTransition(self.kind, target.kind):
    raise newException(ValueError, "Invalid transition " & $self.kind & " -> " & $target.kind)
  self = target

type tuckˑtypeˑVolume* = object
  level*: uint8

proc validate*(self: tuckˑtypeˑVolume) =
  when not defined(tuckNoInvariants):
    if not ((self.level <= 100)): tuckInvariantFailed("(self.level <= 100)", "tuckˑtypeˑVolume")

type tuckˑregistryˑSystemEventsKind* = enum PlaybackStarted, PlaybackStopped, HardwareError
type tuckˑregistryˑSystemEvents* = ref object
  tuckTag*: tuckˑregistryˑSystemEventsKind
  code*: uint8

var latesttuckˑregistryˑSystemEvents*: tuckˑregistryˑSystemEvents

proc raise_tuckˑregistryˑSystemEvents_PlaybackStarted*() =
  latesttuckˑregistryˑSystemEvents = tuckˑregistryˑSystemEvents(tuckTag: PlaybackStarted)
  tuckˑfnˑSystemEvents_PlaybackStarted()

proc raise_tuckˑregistryˑSystemEvents_PlaybackStopped*() =
  latesttuckˑregistryˑSystemEvents = tuckˑregistryˑSystemEvents(tuckTag: PlaybackStopped)
  tuckˑfnˑSystemEvents_PlaybackStopped()

proc raise_tuckˑregistryˑSystemEvents_HardwareError*(code: uint8) =
  latesttuckˑregistryˑSystemEvents = tuckˑregistryˑSystemEvents(tuckTag: HardwareError, code: code)
  tuckˑfnˑSystemEvents_HardwareError(code)


var tuckˑregisterˑDAC_CR = cast[ptr uint32](0x40007400)
const tuckˑregisterˑDAC_CR_EN_SHIFT = 0
const tuckˑregisterˑDAC_CR_BOFF_SHIFT = 1
proc tuckˑregisterˑDAC_CR_EN_get*(): bool {.inline.} =
  (tuckˑregisterˑDAC_CR[] and (1'u32 shl tuckˑregisterˑDAC_CR_EN_SHIFT)) != 0
proc tuckˑregisterˑDAC_CR_EN_set*(value: bool) {.inline.} =
  let mask = 1'u32 shl tuckˑregisterˑDAC_CR_EN_SHIFT
  if value: tuckˑregisterˑDAC_CR[] = tuckˑregisterˑDAC_CR[] or mask
  else: tuckˑregisterˑDAC_CR[] = tuckˑregisterˑDAC_CR[] and not mask
proc tuckˑregisterˑDAC_CR_BOFF_get*(): bool {.inline.} =
  (tuckˑregisterˑDAC_CR[] and (1'u32 shl tuckˑregisterˑDAC_CR_BOFF_SHIFT)) != 0
proc tuckˑregisterˑDAC_CR_BOFF_set*(value: bool) {.inline.} =
  let mask = 1'u32 shl tuckˑregisterˑDAC_CR_BOFF_SHIFT
  if value: tuckˑregisterˑDAC_CR[] = tuckˑregisterˑDAC_CR[] or mask
  else: tuckˑregisterˑDAC_CR[] = tuckˑregisterˑDAC_CR[] and not mask

var tuckˑregisterˑDMA1_CH3 = cast[ptr uint32](0x40020030)
const tuckˑregisterˑDMA1_CH3_EN_SHIFT = 0
const tuckˑregisterˑDMA1_CH3_TCIE_SHIFT = 1
proc tuckˑregisterˑDMA1_CH3_EN_get*(): bool {.inline.} =
  (tuckˑregisterˑDMA1_CH3[] and (1'u32 shl tuckˑregisterˑDMA1_CH3_EN_SHIFT)) != 0
proc tuckˑregisterˑDMA1_CH3_EN_set*(value: bool) {.inline.} =
  let mask = 1'u32 shl tuckˑregisterˑDMA1_CH3_EN_SHIFT
  if value: tuckˑregisterˑDMA1_CH3[] = tuckˑregisterˑDMA1_CH3[] or mask
  else: tuckˑregisterˑDMA1_CH3[] = tuckˑregisterˑDMA1_CH3[] and not mask
proc tuckˑregisterˑDMA1_CH3_TCIE_get*(): bool {.inline.} =
  (tuckˑregisterˑDMA1_CH3[] and (1'u32 shl tuckˑregisterˑDMA1_CH3_TCIE_SHIFT)) != 0
proc tuckˑregisterˑDMA1_CH3_TCIE_set*(value: bool) {.inline.} =
  let mask = 1'u32 shl tuckˑregisterˑDMA1_CH3_TCIE_SHIFT
  if value: tuckˑregisterˑDMA1_CH3[] = tuckˑregisterˑDMA1_CH3[] or mask
  else: tuckˑregisterˑDMA1_CH3[] = tuckˑregisterˑDMA1_CH3[] and not mask

var tuckˑpoolˑBufferPool* = ObjectPool[array[512, uint8], 4]()
proc tuckˑtaskˑstreamReader*(streamId: uint8, chunks: seq[uint32]): TuckResult[tuple[]] =
  for tuckˑvˑi in chunks:
    if true:
      var tuckˑvˑbuf = acquire(tuckˑpoolˑBufferPool)
      if not tuckˑvˑbuf.ok:
        if true:
          return tokVoid()
      tuckˑregisterˑDMA1_CH3_EN_set(true)
      release(tuckˑpoolˑBufferPool, tuckˑvˑbuf.value)

type tuckˑactorˑDecoderMsgKind* = enum msgPlay, msgPause, msgStop
type tuckˑactorˑDecoderMsg* = object
  tuckTag*: tuckˑactorˑDecoderMsgKind
  rate*: tuckˑtypeˑHz

type tuckˑactorˑDecoder* = ref object
  state*: tuckˑtypeˑPlayerState
  vol*: tuckˑtypeˑVolume
  mailbox*: Mailbox[tuckˑactorˑDecoderMsg, 8]

let tuckˑactorˑDecoderSingleton* = tuckˑactorˑDecoder(state: tuckˑtypeˑPlayerState(kind: Idle), vol: (let tuckInv1 = tuckˑtypeˑVolume(level: 80'u8); validate(tuckInv1); tuckInv1))

proc handleMsg*(self: tuckˑactorˑDecoder, msg: tuckˑactorˑDecoderMsg) =
  case msg.tuckTag
  of msgPlay:
    let rate = msg.rate
    if true:
      (case self.state.kind
      of Idle:
        if true:
          self.state = tuckˑtypeˑPlayerState(kind: Decoding, tuckˑvariantˑdecoding: (sampleRate: rate))
          raise_tuckˑregistryˑSystemEvents_PlaybackStarted()
          tuckˑregisterˑDAC_CR_EN_set(true)
      of Paused:
        if true:
          self.state = tuckˑtypeˑPlayerState(kind: Decoding, tuckˑvariantˑdecoding: (sampleRate: rate))
          raise_tuckˑregistryˑSystemEvents_PlaybackStarted()
          tuckˑregisterˑDAC_CR_EN_set(true)
      of Decoding:
        discard)
  of msgPause:
    if true:
      (case self.state.kind
      of Decoding:
        self.state = tuckˑtypeˑPlayerState(kind: Paused)
      of Idle:
        discard
      of Paused:
        discard)
      tuckˑregisterˑDAC_CR_EN_set(false)
  of msgStop:
    if true:
      self.state = tuckˑtypeˑPlayerState(kind: Idle)
      raise_tuckˑregistryˑSystemEvents_PlaybackStopped()
      tuckˑregisterˑDAC_CR_EN_set(false)

proc draintuckˑactorˑDecoder(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    for m in messages(tuckˑactorˑDecoderSingleton.mailbox):
      handleMsg(tuckˑactorˑDecoderSingleton, m)
      tuckCheckWaiters()
      result = true

var tuckˑactorˑDecoderSlot*: pointer
proc registerActortuckˑactorˑDecoder*() =
  tuckˑactorˑDecoderSlot = tuckStartActor(draintuckˑactorˑDecoder)

static: assert((sizeof(tuckˑtypeˑVolume) == 1))
proc tuckˑfnˑSystemEvents_PlaybackStarted*(): void =
  tuckˑregisterˑDAC_CR_EN_set(true)

proc tuckˑfnˑSystemEvents_PlaybackStopped*(): void =
  tuckˑregisterˑDAC_CR_EN_set(false)

proc tuckˑfnˑSystemEvents_HardwareError*(code: uint8): void =
  var tuckˑvˑfailed = code
  tuckˑregisterˑDAC_CR_EN_set(false)

proc tuckˑfnˑmain*(): void =
  discard

