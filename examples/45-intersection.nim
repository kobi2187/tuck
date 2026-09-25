{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import scheduler

proc tuck_fn_nextPhase*(current: tuck_type_Phase, demand: tuck_type_Demand, preempt: bool): tuck_type_Phase
proc tuck_fn_Intersection_PhaseChanged*(to: uint8): void
proc tuck_fn_Intersection_Preempted*(source: uint8): void
proc tuck_fn_seconds*(self: tuck_type_Interval): int
proc tuck_fn_longEnough*[T](span: T, atLeast: int): bool
proc tuck_fn_phaseIndex*(p: tuck_type_Phase): int
proc tuck_fn_poll*(d: Detector): tuck_type_Demand
proc tuck_fn_settled*(): bool
proc tuck_fn_report*(d: Detector): void
proc tuck_fn_drive*(): void
proc tuck_fn_main*(): int

type tuck_type_Phase* = enum NorthSouth, NsClearing, EastWest, EwClearing
proc canTransition*(frm, to: tuck_type_Phase): bool =
  case frm
  of NorthSouth: to in {NsClearing}
  of NsClearing: to in {EastWest}
  of EastWest: to in {EwClearing}
  of EwClearing: to in {NorthSouth}
proc transitionTo*(self: var tuck_type_Phase, target: tuck_type_Phase) =
  if not canTransition(self, target):
    raise newException(ValueError, "Invalid transition " & $self & " -> " & $target)
  self = target

type tuck_type_Demand* = enum quiet, northSouth, eastWest, both

type tuck_type_Interval* = object
  ticks*: int

type tuck_type_LoopDetector* = object
  lane*: int

type tuck_type_CameraDetector* = object
  confidence*: uint8

type DetectorTag* = enum Detector_is_tuck_type_CameraDetector, Detector_is_tuck_type_LoopDetector

type Detector* = object
  case tag*: DetectorTag
  of Detector_is_tuck_type_CameraDetector: tuck_type_CameraDetectorVal*: tuck_type_CameraDetector
  of Detector_is_tuck_type_LoopDetector: tuck_type_LoopDetectorVal*: tuck_type_LoopDetector

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
  tuck_fn_Intersection_PhaseChanged(to)

proc raise_tuck_Intersection_Preempted*(source: uint8) =
  latesttuck_Intersection = tuck_Intersection(tuckTag: Preempted, source: source)
  tuck_fn_Intersection_Preempted(source)


proc tuck_fn_nextPhase*(current: tuck_type_Phase, demand: tuck_type_Demand, preempt: bool): tuck_type_Phase =
  (case (((ord(current) * 8) + (ord(demand) * 2)) + ord(preempt))
  of 0, 2, 24, 25, 26, 27, 28, 29, 30, 31:
    return tuck_type_Phase.NorthSouth
  of 1, 3, 4, 5, 6, 7:
    return tuck_type_Phase.NsClearing
  of 8, 9, 10, 11, 12, 13, 14, 15, 16, 20:
    return tuck_type_Phase.EastWest
  else:
    return tuck_type_Phase.EwClearing)

proc tuck_type_LoopDetector_tuck_fn_healthy*(self: var tuck_type_LoopDetector): bool =
  return true

proc tuck_type_LoopDetector_reads*(self: var tuck_type_LoopDetector): int =
  return self.lane


proc tuck_type_CameraDetector_tuck_fn_healthy*(self: var tuck_type_CameraDetector): bool =
  return true

proc tuck_type_CameraDetector_reads*(self: var tuck_type_CameraDetector): int =
  if (self.confidence > 80):
    if true:
      return 3
  return 0


type tuck_type_SignalsMsgKind* = enum msgSense
type tuck_type_SignalsMsg* = object
  tuckTag*: tuck_type_SignalsMsgKind
  demand*: tuck_type_Demand
  preempt*: bool

type tuck_type_Signals* = ref object
  phase*: tuck_type_Phase
  cycles*: int
  mailbox*: Mailbox[tuck_type_SignalsMsg, 8]

let tuck_type_SignalsSingleton* = tuck_type_Signals(phase: tuck_type_Phase.NorthSouth, cycles: 0)

proc handleMsg*(self: tuck_type_Signals, msg: tuck_type_SignalsMsg) =
  case msg.tuckTag
  of msgSense:
    let demand = msg.demand
    let preempt = msg.preempt
    if true:
      var tuck_want = tuck_fn_nextPhase(self.phase, demand, preempt)
      self.phase = tuck_want
      self.cycles = (self.cycles + 1)

proc draintuck_type_Signals(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    for m in messages(tuck_type_SignalsSingleton.mailbox):
      handleMsg(tuck_type_SignalsSingleton, m)
      tuckCheckWaiters()
      result = true

var tuck_type_SignalsSlot*: pointer
proc registerActortuck_type_Signals*() =
  tuck_type_SignalsSlot = tuckStartActor(draintuck_type_Signals)

proc tuck_fn_Intersection_PhaseChanged*(to: uint8): void =
  tuck_SIGNAL_OUT_WALK_set(false)

proc tuck_fn_Intersection_Preempted*(source: uint8): void =
  tuck_SIGNAL_OUT_NS_GREEN_set(false)

# [codegen] ignored decl kind dkGroup

proc tuck_fn_seconds*(self: tuck_type_Interval): int =
  return (self.ticks div 10)

proc tuck_fn_longEnough*[T](span: T, atLeast: int): bool =
  mixin tuck_fn_seconds
  return (tuck_fn_seconds(span) >= atLeast)

proc tuck_fn_phaseIndex*(p: tuck_type_Phase): int =
  (case p
  of NorthSouth:
    return 0
  of NsClearing:
    return 1
  of EastWest:
    return 2
  of EwClearing:
    return 3)

proc tuck_fn_poll*(d: Detector): tuck_type_Demand =
  var tuck_bits = (block:
    case d.tag
    of Detector_is_tuck_type_CameraDetector:
      var tmp = d.tuck_type_CameraDetectorVal
      tuck_type_CameraDetector_reads(tmp)
    of Detector_is_tuck_type_LoopDetector:
      var tmp = d.tuck_type_LoopDetectorVal
      tuck_type_LoopDetector_reads(tmp))
  (case tuck_bits
  of 1:
    return tuck_type_Demand.northSouth
  of 2:
    return tuck_type_Demand.eastWest
  of 3:
    return tuck_type_Demand.both
  else:
    return tuck_type_Demand.quiet)

proc tuck_fn_settled*(): bool =
  return (tuck_type_SignalsSingleton.cycles > 2)

proc tuck_fn_report*(d: Detector): void =
  var tuck_demand = tuck_fn_poll(d)
  discard enqueue(tuck_type_SignalsSingleton.mailbox, tuck_type_SignalsMsg(tuckTag: msgSense, demand: tuck_demand, preempt: false))
  tuckNotifySend(tuck_type_SignalsSlot)
  return

proc tuck_fn_drive*(): void =
  var tuck_loops = tuck_type_LoopDetector(lane: 1)
  var tuck_camera = tuck_type_CameraDetector(confidence: 91'u8)
  tuck_fn_report(Detector(tag: Detector_is_tuck_type_CameraDetector, tuck_type_CameraDetectorVal: tuck_camera))
  discard enqueue(tuck_type_SignalsSingleton.mailbox, tuck_type_SignalsMsg(tuckTag: msgSense, demand: tuck_type_Demand.quiet, preempt: false))
  tuckNotifySend(tuck_type_SignalsSlot)
  tuck_fn_report(Detector(tag: Detector_is_tuck_type_LoopDetector, tuck_type_LoopDetectorVal: tuck_loops))
  return

proc tuck_fn_main*(): int =
  var tuck_clearing = tuck_type_Interval(ticks: 45)
  var tuck_ok = tuck_fn_longEnough(tuck_clearing, 4)
  if not tuck_ok:
    if true:
      return 9
  tuck_fn_drive()
  tuckWaitOn(tuck_type_SignalsSlot, tuck_fn_settled)
  return tuck_fn_phaseIndex(tuck_type_SignalsSingleton.phase)

