{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import scheduler

proc tuckˑdecisionˑnextPhase*(current: tuckˑtypeˑPhase, demand: tuckˑtypeˑDemand, preempt: bool): tuckˑtypeˑPhase
proc tuckˑfnˑIntersection_PhaseChanged*(to: uint8): void
proc tuckˑfnˑIntersection_Preempted*(source: uint8): void
proc tuckˑfnˑseconds*(self: tuckˑtypeˑInterval): int
proc tuckˑfnˑlongEnough*[T](span: T, atLeast: int): bool
proc tuckˑfnˑphaseIndex*(p: tuckˑtypeˑPhase): int
proc tuckˑfnˑpoll*(d: Detector): tuckˑtypeˑDemand
proc tuckˑfnˑsettled*(): bool
proc tuckˑfnˑreport*(d: Detector): void
proc tuckˑfnˑdrive*(): void
proc tuckˑfnˑmain*(): int

type tuckˑtypeˑPhase* = enum NorthSouth, NsClearing, EastWest, EwClearing
proc canTransition*(frm, to: tuckˑtypeˑPhase): bool =
  case frm
  of NorthSouth: to in {NsClearing}
  of NsClearing: to in {EastWest}
  of EastWest: to in {EwClearing}
  of EwClearing: to in {NorthSouth}
proc transitionTo*(self: var tuckˑtypeˑPhase, target: tuckˑtypeˑPhase) =
  if not canTransition(self, target):
    raise newException(ValueError, "Invalid transition " & $self & " -> " & $target)
  self = target

type tuckˑtypeˑDemand* = enum quiet, northSouth, eastWest, both

type tuckˑtypeˑInterval* = object
  ticks*: int

type tuckˑobjectˑLoopDetector* = object
  lane*: int

type tuckˑobjectˑCameraDetector* = object
  confidence*: uint8

type DetectorTag* = enum Detector_is_tuckˑobjectˑCameraDetector, Detector_is_tuckˑobjectˑLoopDetector

type Detector* = object
  case tag*: DetectorTag
  of Detector_is_tuckˑobjectˑCameraDetector: tuckˑobjectˑCameraDetectorVal*: tuckˑobjectˑCameraDetector
  of Detector_is_tuckˑobjectˑLoopDetector: tuckˑobjectˑLoopDetectorVal*: tuckˑobjectˑLoopDetector

var tuckˑregisterˑSIGNAL_OUT = cast[ptr uint32](0x40011000)
const tuckˑregisterˑSIGNAL_OUT_NS_GREEN_SHIFT = 0
const tuckˑregisterˑSIGNAL_OUT_EW_GREEN_SHIFT = 1
const tuckˑregisterˑSIGNAL_OUT_WALK_SHIFT = 2
proc tuckˑregisterˑSIGNAL_OUT_NS_GREEN_get*(): bool {.inline.} =
  (tuckˑregisterˑSIGNAL_OUT[] and (1'u32 shl tuckˑregisterˑSIGNAL_OUT_NS_GREEN_SHIFT)) != 0
proc tuckˑregisterˑSIGNAL_OUT_NS_GREEN_set*(value: bool) {.inline.} =
  let mask = 1'u32 shl tuckˑregisterˑSIGNAL_OUT_NS_GREEN_SHIFT
  if value: tuckˑregisterˑSIGNAL_OUT[] = tuckˑregisterˑSIGNAL_OUT[] or mask
  else: tuckˑregisterˑSIGNAL_OUT[] = tuckˑregisterˑSIGNAL_OUT[] and not mask
proc tuckˑregisterˑSIGNAL_OUT_EW_GREEN_get*(): bool {.inline.} =
  (tuckˑregisterˑSIGNAL_OUT[] and (1'u32 shl tuckˑregisterˑSIGNAL_OUT_EW_GREEN_SHIFT)) != 0
proc tuckˑregisterˑSIGNAL_OUT_EW_GREEN_set*(value: bool) {.inline.} =
  let mask = 1'u32 shl tuckˑregisterˑSIGNAL_OUT_EW_GREEN_SHIFT
  if value: tuckˑregisterˑSIGNAL_OUT[] = tuckˑregisterˑSIGNAL_OUT[] or mask
  else: tuckˑregisterˑSIGNAL_OUT[] = tuckˑregisterˑSIGNAL_OUT[] and not mask
proc tuckˑregisterˑSIGNAL_OUT_WALK_get*(): bool {.inline.} =
  (tuckˑregisterˑSIGNAL_OUT[] and (1'u32 shl tuckˑregisterˑSIGNAL_OUT_WALK_SHIFT)) != 0
proc tuckˑregisterˑSIGNAL_OUT_WALK_set*(value: bool) {.inline.} =
  let mask = 1'u32 shl tuckˑregisterˑSIGNAL_OUT_WALK_SHIFT
  if value: tuckˑregisterˑSIGNAL_OUT[] = tuckˑregisterˑSIGNAL_OUT[] or mask
  else: tuckˑregisterˑSIGNAL_OUT[] = tuckˑregisterˑSIGNAL_OUT[] and not mask

var tuckˑregisterˑDETECT_IN = cast[ptr uint32](0x40011004)
const tuckˑregisterˑDETECT_IN_NS_LOOP_SHIFT = 0
const tuckˑregisterˑDETECT_IN_EW_LOOP_SHIFT = 1
proc tuckˑregisterˑDETECT_IN_NS_LOOP_get*(): bool {.inline.} =
  (tuckˑregisterˑDETECT_IN[] and (1'u32 shl tuckˑregisterˑDETECT_IN_NS_LOOP_SHIFT)) != 0
proc tuckˑregisterˑDETECT_IN_EW_LOOP_get*(): bool {.inline.} =
  (tuckˑregisterˑDETECT_IN[] and (1'u32 shl tuckˑregisterˑDETECT_IN_EW_LOOP_SHIFT)) != 0

type tuckˑregistryˑIntersectionKind* = enum PhaseChanged, Preempted
type tuckˑregistryˑIntersection* = ref object
  tuckTag*: tuckˑregistryˑIntersectionKind
  to*: uint8
  source*: uint8

var latesttuckˑregistryˑIntersection*: tuckˑregistryˑIntersection

proc raise_tuckˑregistryˑIntersection_PhaseChanged*(to: uint8) =
  latesttuckˑregistryˑIntersection = tuckˑregistryˑIntersection(tuckTag: PhaseChanged, to: to)
  tuckˑfnˑIntersection_PhaseChanged(to)

proc raise_tuckˑregistryˑIntersection_Preempted*(source: uint8) =
  latesttuckˑregistryˑIntersection = tuckˑregistryˑIntersection(tuckTag: Preempted, source: source)
  tuckˑfnˑIntersection_Preempted(source)


proc tuckˑdecisionˑnextPhase*(current: tuckˑtypeˑPhase, demand: tuckˑtypeˑDemand, preempt: bool): tuckˑtypeˑPhase =
  (case (((ord(current) * 8) + (ord(demand) * 2)) + ord(preempt))
  of 0, 2, 24, 25, 26, 27, 28, 29, 30, 31:
    return tuckˑtypeˑPhase.NorthSouth
  of 1, 3, 4, 5, 6, 7:
    return tuckˑtypeˑPhase.NsClearing
  of 8, 9, 10, 11, 12, 13, 14, 15, 16, 20:
    return tuckˑtypeˑPhase.EastWest
  else:
    return tuckˑtypeˑPhase.EwClearing)

proc tuckˑobjectˑLoopDetectorˑtuckˑfnˑhealthy*(self: var tuckˑobjectˑLoopDetector): bool =
  return true

proc tuckˑobjectˑLoopDetectorˑreads*(self: var tuckˑobjectˑLoopDetector): int =
  return self.lane


proc tuckˑobjectˑCameraDetectorˑtuckˑfnˑhealthy*(self: var tuckˑobjectˑCameraDetector): bool =
  return true

proc tuckˑobjectˑCameraDetectorˑreads*(self: var tuckˑobjectˑCameraDetector): int =
  if (self.confidence > 80):
    if true:
      return 3
  return 0


type tuckˑactorˑSignalsMsgKind* = enum msgSense
type tuckˑactorˑSignalsMsg* = object
  tuckTag*: tuckˑactorˑSignalsMsgKind
  demand*: tuckˑtypeˑDemand
  preempt*: bool

type tuckˑactorˑSignals* = ref object
  phase*: tuckˑtypeˑPhase
  cycles*: int
  mailbox*: Mailbox[tuckˑactorˑSignalsMsg, 8]

let tuckˑactorˑSignalsSingleton* = tuckˑactorˑSignals(phase: tuckˑtypeˑPhase.NorthSouth, cycles: 0)

proc handleMsg*(self: tuckˑactorˑSignals, msg: tuckˑactorˑSignalsMsg) =
  case msg.tuckTag
  of msgSense:
    let demand = msg.demand
    let preempt = msg.preempt
    if true:
      var tuckˑvˑwant = tuckˑdecisionˑnextPhase(self.phase, demand, preempt)
      self.phase = tuckˑvˑwant
      self.cycles = (self.cycles + 1)

proc draintuckˑactorˑSignals(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    for m in messages(tuckˑactorˑSignalsSingleton.mailbox):
      handleMsg(tuckˑactorˑSignalsSingleton, m)
      tuckCheckWaiters()
      result = true

var tuckˑactorˑSignalsSlot*: pointer
proc registerActortuckˑactorˑSignals*() =
  tuckˑactorˑSignalsSlot = tuckStartActor(draintuckˑactorˑSignals)

proc tuckˑfnˑIntersection_PhaseChanged*(to: uint8): void =
  tuckˑregisterˑSIGNAL_OUT_WALK_set(false)

proc tuckˑfnˑIntersection_Preempted*(source: uint8): void =
  tuckˑregisterˑSIGNAL_OUT_NS_GREEN_set(false)

proc tuckˑfnˑseconds*(self: tuckˑtypeˑInterval): int =
  return (self.ticks div 10)

proc tuckˑfnˑlongEnough*[T](span: T, atLeast: int): bool =
  mixin tuckˑfnˑseconds
  return (tuckˑfnˑseconds(span) >= atLeast)

proc tuckˑfnˑphaseIndex*(p: tuckˑtypeˑPhase): int =
  (case p
  of NorthSouth:
    return 0
  of NsClearing:
    return 1
  of EastWest:
    return 2
  of EwClearing:
    return 3)

proc tuckˑfnˑpoll*(d: Detector): tuckˑtypeˑDemand =
  var tuckˑvˑbits = (block:
    case d.tag
    of Detector_is_tuckˑobjectˑCameraDetector:
      var tmp = d.tuckˑobjectˑCameraDetectorVal
      tuckˑobjectˑCameraDetectorˑreads(tmp)
    of Detector_is_tuckˑobjectˑLoopDetector:
      var tmp = d.tuckˑobjectˑLoopDetectorVal
      tuckˑobjectˑLoopDetectorˑreads(tmp))
  (case tuckˑvˑbits
  of 1:
    return tuckˑtypeˑDemand.northSouth
  of 2:
    return tuckˑtypeˑDemand.eastWest
  of 3:
    return tuckˑtypeˑDemand.both
  else:
    return tuckˑtypeˑDemand.quiet)

proc tuckˑfnˑsettled*(): bool =
  return (tuckˑactorˑSignalsSingleton.cycles > 2)

proc tuckˑfnˑreport*(d: Detector): void =
  var tuckˑvˑdemand = tuckˑfnˑpoll(d)
  discard enqueue(tuckˑactorˑSignalsSingleton.mailbox, tuckˑactorˑSignalsMsg(tuckTag: msgSense, demand: tuckˑvˑdemand, preempt: false))
  tuckNotifySend(tuckˑactorˑSignalsSlot)
  return

proc tuckˑfnˑdrive*(): void =
  var tuckˑvˑloops = tuckˑobjectˑLoopDetector(lane: 1)
  var tuckˑvˑcamera = tuckˑobjectˑCameraDetector(confidence: 91'u8)
  tuckˑfnˑreport(Detector(tag: Detector_is_tuckˑobjectˑCameraDetector, tuckˑobjectˑCameraDetectorVal: tuckˑvˑcamera))
  discard enqueue(tuckˑactorˑSignalsSingleton.mailbox, tuckˑactorˑSignalsMsg(tuckTag: msgSense, demand: tuckˑtypeˑDemand.quiet, preempt: false))
  tuckNotifySend(tuckˑactorˑSignalsSlot)
  tuckˑfnˑreport(Detector(tag: Detector_is_tuckˑobjectˑLoopDetector, tuckˑobjectˑLoopDetectorVal: tuckˑvˑloops))
  return

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑclearing = tuckˑtypeˑInterval(ticks: 45)
  var tuckˑvˑok = tuckˑfnˑlongEnough(tuckˑvˑclearing, 4)
  if not tuckˑvˑok:
    if true:
      return 9
  tuckˑfnˑdrive()
  tuckWaitOn(tuckˑactorˑSignalsSlot, tuckˑfnˑsettled)
  return tuckˑfnˑphaseIndex(tuckˑactorˑSignalsSingleton.phase)

