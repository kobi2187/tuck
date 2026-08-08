import ../compiler/tuck_rt

type tuck_Hz* = distinct uint32
proc `+`*(a, b: tuck_Hz): tuck_Hz {.borrow.}
proc `-`*(a, b: tuck_Hz): tuck_Hz {.borrow.}
proc `*`*(a, b: tuck_Hz): tuck_Hz {.borrow.}
proc `div`*(a, b: tuck_Hz): tuck_Hz {.borrow.}
proc `mod`*(a, b: tuck_Hz): tuck_Hz {.borrow.}
proc `==`*(a, b: tuck_Hz): bool {.borrow.}
proc `<`*(a, b: tuck_Hz): bool {.borrow.}
proc `<=`*(a, b: tuck_Hz): bool {.borrow.}
proc `$`*(a: tuck_Hz): string {.borrow.}

type tuck_Milliseconds* = distinct uint32
proc `+`*(a, b: tuck_Milliseconds): tuck_Milliseconds {.borrow.}
proc `-`*(a, b: tuck_Milliseconds): tuck_Milliseconds {.borrow.}
proc `*`*(a, b: tuck_Milliseconds): tuck_Milliseconds {.borrow.}
proc `div`*(a, b: tuck_Milliseconds): tuck_Milliseconds {.borrow.}
proc `mod`*(a, b: tuck_Milliseconds): tuck_Milliseconds {.borrow.}
proc `==`*(a, b: tuck_Milliseconds): bool {.borrow.}
proc `<`*(a, b: tuck_Milliseconds): bool {.borrow.}
proc `<=`*(a, b: tuck_Milliseconds): bool {.borrow.}
proc `$`*(a: tuck_Milliseconds): string {.borrow.}

type tuck_PlayerStateKind* = enum Idle, Decoding, Paused
type tuck_PlayerState* = object
  case kind*: tuck_PlayerStateKind
  of Idle: discard
  of Decoding: decoding*: tuple[sampleRate: tuck_Hz]
  of Paused: discard
proc canTransition*(frm, to: tuck_PlayerStateKind): bool =
  case frm
  of Idle: to in {Decoding}
  of Decoding: to in {Paused, Idle}
  of Paused: to in {Decoding, Idle}
proc transitionTo*(self: var tuck_PlayerState, target: tuck_PlayerState) =
  if not canTransition(self.kind, target.kind):
    raise newException(ValueError, "Invalid transition " & $self.kind & " -> " & $target.kind)
  self = target

type tuck_Volume* = object
    level*: uint8

proc validate*(self: tuck_Volume) =
  when not defined(release):
    assert((self.level <= 100), "Invariant violated: (self.level <= 100)")

type tuck_SystemEventsKind* = enum PlaybackStarted, PlaybackStopped, HardwareError
type tuck_SystemEvents* = ref object
    kind*: tuck_SystemEventsKind
    code*: uint8

var latesttuck_SystemEvents*: tuck_SystemEvents

proc raise_tuck_SystemEvents_PlaybackStarted*() =
  latesttuck_SystemEvents = tuck_SystemEvents(kind: PlaybackStarted)
  discard

proc raise_tuck_SystemEvents_PlaybackStopped*() =
  latesttuck_SystemEvents = tuck_SystemEvents(kind: PlaybackStopped)
  discard

proc raise_tuck_SystemEvents_HardwareError*(code: uint8) =
  latesttuck_SystemEvents = tuck_SystemEvents(kind: HardwareError, code: code)
  discard


registerMMIO(tuck_DAC_CR, 0x40007400):
  EN: bit(0, ReadWrite)
  BOFF: bit(1, ReadWrite)

registerMMIO(tuck_DMA1_CH3, 0x40020030):
  EN: bit(0, ReadWrite)
  TCIE: bit(1, ReadWrite)

var tuck_BufferPool* = ObjectPool[array[512, uint8], 4]()
proc tuck_streamReader*(streamId: uint8, chunks: seq[uint32]): TuckResult[tuple[]] =
  for i in chunks:
    if true:
      var buf = acquire(tuck_BufferPool)
      if not buf.ok:
        if true:
          return tokVoid()
      tuck_DMA1_CH3.EN = true
      release(tuck_BufferPool, buf.value)

type tuck_DecoderMsgKind* = enum msgPlay, msgPause, msgStop
type tuck_DecoderMsg* = object
  kind*: tuck_DecoderMsgKind
  rate*: tuck_Hz

type tuck_Decoder* = ref object
    state*: tuck_PlayerState
    vol*: tuck_Volume
    mailbox*: Mailbox[tuck_DecoderMsg, 8]

let tuck_DecoderSingleton* = tuck_Decoder()

proc handleMsg*(self: tuck_Decoder, msg: tuck_DecoderMsg) =
  case msg.kind
  of msgPlay:
    let rate = msg.rate
    if true:
      (case self.state
      of Idle:
        if true:
          self.state = tuck_PlayerState(kind: Decoding, decoding: (sampleRate: rate))
          PlaybackStarted(tuck_SystemEvents.raise)
          tuck_DAC_CR.EN = true
      of Paused:
        if true:
          self.state = tuck_PlayerState(kind: Decoding, decoding: (sampleRate: rate))
          PlaybackStarted(tuck_SystemEvents.raise)
          tuck_DAC_CR.EN = true
      of Decoding:
        discard)
  of msgPause:
    if true:
      (case self.state
      of Decoding:
        self.state = tuck_PlayerState(kind: Paused)
      of Idle:
        discard
      of Paused:
        discard)
      tuck_DAC_CR.EN = false
  of msgStop:
    if true:
      self.state = tuck_PlayerState(kind: Idle)
      PlaybackStopped(tuck_SystemEvents.raise)
      tuck_DAC_CR.EN = false

proc draintuck_Decoder(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    var m: tuck_DecoderMsg
    while dequeue(tuck_DecoderSingleton.mailbox, m):
      handleMsg(tuck_DecoderSingleton, m)
      result = true

proc registerActortuck_Decoder*() =
  tuckStartActor(draintuck_Decoder)

static: assert((sizeof(tuck_Volume) == 1))
proc tuck_main*(): void =
  discard

