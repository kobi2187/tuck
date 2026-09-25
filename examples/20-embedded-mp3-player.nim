{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc `==`*(a, b: tuck_type_PlayerState): bool {.noSideEffect.}

proc tuck_fn_SystemEvents_PlaybackStarted*(): void
proc tuck_fn_SystemEvents_PlaybackStopped*(): void
proc tuck_fn_SystemEvents_HardwareError*(code: uint8): void
proc tuck_fn_main*(): void

type tuck_type_Hz* = distinct uint32
proc `+`*(a, b: tuck_type_Hz): tuck_type_Hz {.borrow.}
proc `-`*(a, b: tuck_type_Hz): tuck_type_Hz {.borrow.}
proc `*`*(a, b: tuck_type_Hz): tuck_type_Hz {.borrow.}
proc `div`*(a, b: tuck_type_Hz): tuck_type_Hz {.borrow.}
proc `mod`*(a, b: tuck_type_Hz): tuck_type_Hz {.borrow.}
proc `==`*(a, b: tuck_type_Hz): bool {.borrow.}
proc `<`*(a, b: tuck_type_Hz): bool {.borrow.}
proc `<=`*(a, b: tuck_type_Hz): bool {.borrow.}
proc `$`*(a: tuck_type_Hz): string {.borrow.}

type tuck_type_Milliseconds* = distinct uint32
proc `+`*(a, b: tuck_type_Milliseconds): tuck_type_Milliseconds {.borrow.}
proc `-`*(a, b: tuck_type_Milliseconds): tuck_type_Milliseconds {.borrow.}
proc `*`*(a, b: tuck_type_Milliseconds): tuck_type_Milliseconds {.borrow.}
proc `div`*(a, b: tuck_type_Milliseconds): tuck_type_Milliseconds {.borrow.}
proc `mod`*(a, b: tuck_type_Milliseconds): tuck_type_Milliseconds {.borrow.}
proc `==`*(a, b: tuck_type_Milliseconds): bool {.borrow.}
proc `<`*(a, b: tuck_type_Milliseconds): bool {.borrow.}
proc `<=`*(a, b: tuck_type_Milliseconds): bool {.borrow.}
proc `$`*(a: tuck_type_Milliseconds): string {.borrow.}

type tuck_type_PlayerStateKind* = enum Idle, Decoding, Paused
type tuck_type_PlayerState* = object
  case kind*: tuck_type_PlayerStateKind
  of Idle: discard
  of Decoding: tuck_decoding*: tuple[sampleRate: tuck_type_Hz]
  of Paused: discard

proc `==`*(a, b: tuck_type_PlayerState): bool {.noSideEffect.} =
  if a.kind != b.kind: return false
  case a.kind
  of Idle: true
  of Decoding: a.tuck_decoding == b.tuck_decoding
  of Paused: true
proc canTransition*(frm, to: tuck_type_PlayerStateKind): bool =
  case frm
  of Idle: to in {Decoding}
  of Decoding: to in {Paused, Idle}
  of Paused: to in {Decoding, Idle}
proc transitionTo*(self: var tuck_type_PlayerState, target: tuck_type_PlayerState) =
  if not canTransition(self.kind, target.kind):
    raise newException(ValueError, "Invalid transition " & $self.kind & " -> " & $target.kind)
  self = target

type tuck_type_Volume* = object
  level*: uint8

proc validate*(self: tuck_type_Volume) =
  when not defined(tuckNoInvariants):
    if not ((self.level <= 100)): tuckInvariantFailed("(self.level <= 100)", "tuck_type_Volume")

type tuck_SystemEventsKind* = enum PlaybackStarted, PlaybackStopped, HardwareError
type tuck_SystemEvents* = ref object
  tuckTag*: tuck_SystemEventsKind
  code*: uint8

var latesttuck_SystemEvents*: tuck_SystemEvents

proc raise_tuck_SystemEvents_PlaybackStarted*() =
  latesttuck_SystemEvents = tuck_SystemEvents(tuckTag: PlaybackStarted)
  tuck_fn_SystemEvents_PlaybackStarted()

proc raise_tuck_SystemEvents_PlaybackStopped*() =
  latesttuck_SystemEvents = tuck_SystemEvents(tuckTag: PlaybackStopped)
  tuck_fn_SystemEvents_PlaybackStopped()

proc raise_tuck_SystemEvents_HardwareError*(code: uint8) =
  latesttuck_SystemEvents = tuck_SystemEvents(tuckTag: HardwareError, code: code)
  tuck_fn_SystemEvents_HardwareError(code)


var tuck_DAC_CR = cast[ptr uint32](0x40007400)
const tuck_DAC_CR_EN_SHIFT = 0
const tuck_DAC_CR_BOFF_SHIFT = 1
proc tuck_DAC_CR_EN_get*(): bool {.inline.} =
  (tuck_DAC_CR[] and (1'u32 shl tuck_DAC_CR_EN_SHIFT)) != 0
proc tuck_DAC_CR_EN_set*(value: bool) {.inline.} =
  let mask = 1'u32 shl tuck_DAC_CR_EN_SHIFT
  if value: tuck_DAC_CR[] = tuck_DAC_CR[] or mask
  else: tuck_DAC_CR[] = tuck_DAC_CR[] and not mask
proc tuck_DAC_CR_BOFF_get*(): bool {.inline.} =
  (tuck_DAC_CR[] and (1'u32 shl tuck_DAC_CR_BOFF_SHIFT)) != 0
proc tuck_DAC_CR_BOFF_set*(value: bool) {.inline.} =
  let mask = 1'u32 shl tuck_DAC_CR_BOFF_SHIFT
  if value: tuck_DAC_CR[] = tuck_DAC_CR[] or mask
  else: tuck_DAC_CR[] = tuck_DAC_CR[] and not mask

var tuck_DMA1_CH3 = cast[ptr uint32](0x40020030)
const tuck_DMA1_CH3_EN_SHIFT = 0
const tuck_DMA1_CH3_TCIE_SHIFT = 1
proc tuck_DMA1_CH3_EN_get*(): bool {.inline.} =
  (tuck_DMA1_CH3[] and (1'u32 shl tuck_DMA1_CH3_EN_SHIFT)) != 0
proc tuck_DMA1_CH3_EN_set*(value: bool) {.inline.} =
  let mask = 1'u32 shl tuck_DMA1_CH3_EN_SHIFT
  if value: tuck_DMA1_CH3[] = tuck_DMA1_CH3[] or mask
  else: tuck_DMA1_CH3[] = tuck_DMA1_CH3[] and not mask
proc tuck_DMA1_CH3_TCIE_get*(): bool {.inline.} =
  (tuck_DMA1_CH3[] and (1'u32 shl tuck_DMA1_CH3_TCIE_SHIFT)) != 0
proc tuck_DMA1_CH3_TCIE_set*(value: bool) {.inline.} =
  let mask = 1'u32 shl tuck_DMA1_CH3_TCIE_SHIFT
  if value: tuck_DMA1_CH3[] = tuck_DMA1_CH3[] or mask
  else: tuck_DMA1_CH3[] = tuck_DMA1_CH3[] and not mask

var tuck_BufferPool* = ObjectPool[array[512, uint8], 4]()
proc tuck_fn_streamReader*(streamId: uint8, chunks: seq[uint32]): TuckResult[tuple[]] =
  for tuck_i in chunks:
    if true:
      var tuck_buf = acquire(tuck_BufferPool)
      if not tuck_buf.ok:
        if true:
          return tokVoid()
      tuck_DMA1_CH3_EN_set(true)
      release(tuck_BufferPool, tuck_buf.value)

type tuck_type_DecoderMsgKind* = enum msgPlay, msgPause, msgStop
type tuck_type_DecoderMsg* = object
  tuckTag*: tuck_type_DecoderMsgKind
  rate*: tuck_type_Hz

type tuck_type_Decoder* = ref object
  state*: tuck_type_PlayerState
  vol*: tuck_type_Volume
  mailbox*: Mailbox[tuck_type_DecoderMsg, 8]

let tuck_type_DecoderSingleton* = tuck_type_Decoder(state: tuck_type_PlayerState(kind: Idle), vol: (let tuckInv1 = tuck_type_Volume(level: 80'u8); validate(tuckInv1); tuckInv1))

proc handleMsg*(self: tuck_type_Decoder, msg: tuck_type_DecoderMsg) =
  case msg.tuckTag
  of msgPlay:
    let rate = msg.rate
    if true:
      (case self.state.kind
      of Idle:
        if true:
          self.state = tuck_type_PlayerState(kind: Decoding, tuck_decoding: (sampleRate: rate))
          raise_tuck_SystemEvents_PlaybackStarted()
          tuck_DAC_CR_EN_set(true)
      of Paused:
        if true:
          self.state = tuck_type_PlayerState(kind: Decoding, tuck_decoding: (sampleRate: rate))
          raise_tuck_SystemEvents_PlaybackStarted()
          tuck_DAC_CR_EN_set(true)
      of Decoding:
        discard)
  of msgPause:
    if true:
      (case self.state.kind
      of Decoding:
        self.state = tuck_type_PlayerState(kind: Paused)
      of Idle:
        discard
      of Paused:
        discard)
      tuck_DAC_CR_EN_set(false)
  of msgStop:
    if true:
      self.state = tuck_type_PlayerState(kind: Idle)
      raise_tuck_SystemEvents_PlaybackStopped()
      tuck_DAC_CR_EN_set(false)

proc draintuck_type_Decoder(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    for m in messages(tuck_type_DecoderSingleton.mailbox):
      handleMsg(tuck_type_DecoderSingleton, m)
      tuckCheckWaiters()
      result = true

var tuck_type_DecoderSlot*: pointer
proc registerActortuck_type_Decoder*() =
  tuck_type_DecoderSlot = tuckStartActor(draintuck_type_Decoder)

static: assert((sizeof(tuck_type_Volume) == 1))
proc tuck_fn_SystemEvents_PlaybackStarted*(): void =
  tuck_DAC_CR_EN_set(true)

proc tuck_fn_SystemEvents_PlaybackStopped*(): void =
  tuck_DAC_CR_EN_set(false)

proc tuck_fn_SystemEvents_HardwareError*(code: uint8): void =
  var tuck_failed = code
  tuck_DAC_CR_EN_set(false)

proc tuck_fn_main*(): void =
  discard

