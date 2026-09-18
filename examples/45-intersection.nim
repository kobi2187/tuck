{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import scheduler

proc tuck_Intersection_PhaseChanged*(to: uint8): void
proc tuck_Intersection_Preempted*(source: uint8): void
proc tuck_seconds*(self: tuck_Interval): int
proc tuck_longEnough*[T](span: T, atLeast: int): bool
proc tuck_phaseIndex*(p: tuck_Phase): int
proc tuck_poll*(d: Detector): tuck_Demand
proc tuck_settled*(): bool
proc tuck_report*(d: Detector): void
proc tuck_drive*(): void
proc tuck_main*(): int

type tuck_Phase* = enum NorthSouth, NsClearing, EastWest, EwClearing
proc canTransition*(frm, to: tuck_Phase): bool =
  case frm
  of NorthSouth: to in {NsClearing}
  of NsClearing: to in {EastWest}
  of EastWest: to in {EwClearing}
  of EwClearing: to in {NorthSouth}
proc transitionTo*(self: var tuck_Phase, target: tuck_Phase) =
  if not canTransition(self, target):
    raise newException(ValueError, "Invalid transition " & $self & " -> " & $target)
  self = target

type tuck_Demand* = enum quiet, northSouth, eastWest, both

type tuck_Interval* = object
  ticks*: int

type tuck_LoopDetector* = object
  lane*: int

type tuck_CameraDetector* = object
  confidence*: uint8

type DetectorTag* = enum Detector_is_tuck_CameraDetector, Detector_is_tuck_LoopDetector

type Detector* = object
  case tag*: DetectorTag
  of Detector_is_tuck_CameraDetector: tuck_CameraDetectorVal*: tuck_CameraDetector
  of Detector_is_tuck_LoopDetector: tuck_LoopDetectorVal*: tuck_LoopDetector

var tuck_SIGNAL_OUT = cast[ptr uint32](0x40011000)
const tuck_SIGNAL_OUT_NS_GREEN_SHIFT = 0
const tuck_SIGNAL_OUT_EW_GREEN_SHIFT = 1
const tuck_SIGNAL_OUT_WALK_SHIFT = 2
proc tuck_SIGNAL_OUT_NS_GREEN_get*(): bool {.inline.} =
  (tuck_SIGNAL_OUT[] and (1'u32 shl tuck_SIGNAL_OUT_NS_GREEN_SHIFT)) != 0
proc tuck_SIGNAL_OUT_NS_GREEN_set*(value: bool) {.inline.} =
  let mask = 1'u32 shl tuck_SIGNAL_OUT_NS_GREEN_SHIFT
  if value: tuck_SIGNAL_OUT[] = tuck_SIGNAL_OUT[] or mask
  else: tuck_SIGNAL_OUT[] = tuck_SIGNAL_OUT[] and not mask
proc tuck_SIGNAL_OUT_EW_GREEN_get*(): bool {.inline.} =
  (tuck_SIGNAL_OUT[] and (1'u32 shl tuck_SIGNAL_OUT_EW_GREEN_SHIFT)) != 0
proc tuck_SIGNAL_OUT_EW_GREEN_set*(value: bool) {.inline.} =
  let mask = 1'u32 shl tuck_SIGNAL_OUT_EW_GREEN_SHIFT
  if value: tuck_SIGNAL_OUT[] = tuck_SIGNAL_OUT[] or mask
  else: tuck_SIGNAL_OUT[] = tuck_SIGNAL_OUT[] and not mask
proc tuck_SIGNAL_OUT_WALK_get*(): bool {.inline.} =
  (tuck_SIGNAL_OUT[] and (1'u32 shl tuck_SIGNAL_OUT_WALK_SHIFT)) != 0
proc tuck_SIGNAL_OUT_WALK_set*(value: bool) {.inline.} =
  let mask = 1'u32 shl tuck_SIGNAL_OUT_WALK_SHIFT
  if value: tuck_SIGNAL_OUT[] = tuck_SIGNAL_OUT[] or mask
  else: tuck_SIGNAL_OUT[] = tuck_SIGNAL_OUT[] and not mask

var tuck_DETECT_IN = cast[ptr uint32](0x40011004)
const tuck_DETECT_IN_NS_LOOP_SHIFT = 0
const tuck_DETECT_IN_EW_LOOP_SHIFT = 1
proc tuck_DETECT_IN_NS_LOOP_get*(): bool {.inline.} =
  (tuck_DETECT_IN[] and (1'u32 shl tuck_DETECT_IN_NS_LOOP_SHIFT)) != 0
proc tuck_DETECT_IN_EW_LOOP_get*(): bool {.inline.} =
  (tuck_DETECT_IN[] and (1'u32 shl tuck_DETECT_IN_EW_LOOP_SHIFT)) != 0

type tuck_IntersectionKind* = enum PhaseChanged, Preempted
type tuck_Intersection* = ref object
  tuckTag*: tuck_IntersectionKind
  to*: uint8
  source*: uint8

var latesttuck_Intersection*: tuck_Intersection

proc raise_tuck_Intersection_PhaseChanged*(to: uint8) =
  latesttuck_Intersection = tuck_Intersection(tuckTag: PhaseChanged, to: to)
  tuck_Intersection_PhaseChanged(to)

proc raise_tuck_Intersection_Preempted*(source: uint8) =
  latesttuck_Intersection = tuck_Intersection(tuckTag: Preempted, source: source)
  tuck_Intersection_Preempted(source)


proc tuck_nextPhase*(current: tuck_Phase, demand: tuck_Demand, preempt: bool): tuck_Phase =
  case ord(current) * 8 + ord(demand) * 2 + ord(preempt)   # packed decision key
  of 0, 2, 24, 25, 26, 27, 28, 29, 30, 31: return tuck_Phase.NorthSouth
  of 1, 3, 4, 5, 6, 7: return tuck_Phase.NsClearing
  of 8, 9, 10, 11, 12, 13, 14, 15, 16, 20: return tuck_Phase.EastWest
  else: return tuck_Phase.EwClearing

proc tuck_LoopDetector_tuck_healthy*(self: var tuck_LoopDetector): bool =
  return true

proc tuck_LoopDetector_reads*(self: var tuck_LoopDetector): int =
  return self.lane


proc tuck_CameraDetector_tuck_healthy*(self: var tuck_CameraDetector): bool =
  return true

proc tuck_CameraDetector_reads*(self: var tuck_CameraDetector): int =
  if (self.confidence > 80):
    if true:
      return 3
  return 0


type tuck_SignalsMsgKind* = enum msgSense
type tuck_SignalsMsg* = object
  tuckTag*: tuck_SignalsMsgKind
  demand*: tuck_Demand
  preempt*: bool

type tuck_Signals* = ref object
  phase*: tuck_Phase
  cycles*: int
  mailbox*: Mailbox[tuck_SignalsMsg, 8]

let tuck_SignalsSingleton* = tuck_Signals()

proc handleMsg*(self: tuck_Signals, msg: tuck_SignalsMsg) =
  case msg.tuckTag
  of msgSense:
    let demand = msg.demand
    let preempt = msg.preempt
    if true:
      var tuck_want = tuck_nextPhase(self.phase, demand, preempt)
      self.phase = tuck_want
      self.cycles = (self.cycles + 1)

proc draintuck_Signals(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    var m: tuck_SignalsMsg
    while dequeue(tuck_SignalsSingleton.mailbox, m):
      handleMsg(tuck_SignalsSingleton, m)
      tuckCheckWaiters()
      result = true

var tuck_SignalsSlot*: pointer
proc registerActortuck_Signals*() =
  tuck_SignalsSlot = tuckStartActor(draintuck_Signals)

proc tuck_Intersection_PhaseChanged*(to: uint8): void =
  tuck_SIGNAL_OUT_WALK_set(false)

proc tuck_Intersection_Preempted*(source: uint8): void =
  tuck_SIGNAL_OUT_NS_GREEN_set(false)

# [codegen] ignored decl kind dkGroup

proc tuck_seconds*(self: tuck_Interval): int =
  return (self.ticks div 10)

proc tuck_longEnough*[T](span: T, atLeast: int): bool =
  mixin tuck_seconds
  return (tuck_seconds(span) >= atLeast)

proc tuck_phaseIndex*(p: tuck_Phase): int =
  (case p
  of NorthSouth:
    return 0
  of NsClearing:
    return 1
  of EastWest:
    return 2
  of EwClearing:
    return 3)

proc tuck_poll*(d: Detector): tuck_Demand =
  var tuck_bits = (block:
    case d.tag
    of Detector_is_tuck_CameraDetector:
      var tmp = d.tuck_CameraDetectorVal
      tuck_CameraDetector_reads(tmp)
    of Detector_is_tuck_LoopDetector:
      var tmp = d.tuck_LoopDetectorVal
      tuck_LoopDetector_reads(tmp))
  (case tuck_bits
  of 1:
    return tuck_Demand.northSouth
  of 2:
    return tuck_Demand.eastWest
  of 3:
    return tuck_Demand.both
  else:
    return tuck_Demand.quiet)

proc tuck_settled*(): bool =
  return (tuck_SignalsSingleton.cycles > 2)

proc tuck_report*(d: Detector): void =
  var tuck_demand = tuck_poll(d)
  discard enqueue(tuck_SignalsSingleton.mailbox, tuck_SignalsMsg(tuckTag: msgSense, demand: tuck_demand, preempt: false))
  tuckNotifySend()
  return

proc tuck_drive*(): void =
  var tuck_loops = tuck_LoopDetector(lane: 1)
  var tuck_camera = tuck_CameraDetector(confidence: 91'u8)
  tuck_report(Detector(tag: Detector_is_tuck_CameraDetector, tuck_CameraDetectorVal: tuck_camera))
  discard enqueue(tuck_SignalsSingleton.mailbox, tuck_SignalsMsg(tuckTag: msgSense, demand: tuck_Demand.quiet, preempt: false))
  tuckNotifySend()
  tuck_report(Detector(tag: Detector_is_tuck_LoopDetector, tuck_LoopDetectorVal: tuck_loops))
  return

proc tuck_main*(): int =
  var tuck_clearing = tuck_Interval(ticks: 45)
  var tuck_ok = tuck_longEnough(tuck_clearing, 4)
  if not tuck_ok:
    if true:
      return 9
  tuck_drive()
  tuckWaitOn(tuck_SignalsSlot, tuck_settled)
  return tuck_phaseIndex(tuck_SignalsSingleton.phase)

