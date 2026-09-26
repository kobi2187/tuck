#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"

tuckˑregisterˑSIGNAL_OUT := cast(^u32)(uintptr(0x40011000))
tuckˑregisterˑSIGNAL_OUT_NS_GREEN_SHIFT :: 0
tuckˑregisterˑSIGNAL_OUT_EW_GREEN_SHIFT :: 1
tuckˑregisterˑSIGNAL_OUT_WALK_SHIFT :: 2
tuckˑregisterˑSIGNAL_OUT_NS_GREEN_get :: proc() -> bool {
	return (tuckˑregisterˑSIGNAL_OUT^ & (u32(1) << u32(tuckˑregisterˑSIGNAL_OUT_NS_GREEN_SHIFT))) != 0
}
tuckˑregisterˑSIGNAL_OUT_NS_GREEN_set :: proc(on: bool) {
	mask := u32(1) << u32(tuckˑregisterˑSIGNAL_OUT_NS_GREEN_SHIFT)
	if on { tuckˑregisterˑSIGNAL_OUT^ |= mask } else { tuckˑregisterˑSIGNAL_OUT^ &~= mask }
}
tuckˑregisterˑSIGNAL_OUT_EW_GREEN_get :: proc() -> bool {
	return (tuckˑregisterˑSIGNAL_OUT^ & (u32(1) << u32(tuckˑregisterˑSIGNAL_OUT_EW_GREEN_SHIFT))) != 0
}
tuckˑregisterˑSIGNAL_OUT_EW_GREEN_set :: proc(on: bool) {
	mask := u32(1) << u32(tuckˑregisterˑSIGNAL_OUT_EW_GREEN_SHIFT)
	if on { tuckˑregisterˑSIGNAL_OUT^ |= mask } else { tuckˑregisterˑSIGNAL_OUT^ &~= mask }
}
tuckˑregisterˑSIGNAL_OUT_WALK_get :: proc() -> bool {
	return (tuckˑregisterˑSIGNAL_OUT^ & (u32(1) << u32(tuckˑregisterˑSIGNAL_OUT_WALK_SHIFT))) != 0
}
tuckˑregisterˑSIGNAL_OUT_WALK_set :: proc(on: bool) {
	mask := u32(1) << u32(tuckˑregisterˑSIGNAL_OUT_WALK_SHIFT)
	if on { tuckˑregisterˑSIGNAL_OUT^ |= mask } else { tuckˑregisterˑSIGNAL_OUT^ &~= mask }
}

tuckˑregisterˑDETECT_IN := cast(^u32)(uintptr(0x40011004))
tuckˑregisterˑDETECT_IN_NS_LOOP_SHIFT :: 0
tuckˑregisterˑDETECT_IN_EW_LOOP_SHIFT :: 1
tuckˑregisterˑDETECT_IN_NS_LOOP_get :: proc() -> bool {
	return (tuckˑregisterˑDETECT_IN^ & (u32(1) << u32(tuckˑregisterˑDETECT_IN_NS_LOOP_SHIFT))) != 0
}
tuckˑregisterˑDETECT_IN_EW_LOOP_get :: proc() -> bool {
	return (tuckˑregisterˑDETECT_IN^ & (u32(1) << u32(tuckˑregisterˑDETECT_IN_EW_LOOP_SHIFT))) != 0
}

tuckˑregistryˑIntersectionKind :: enum { PhaseChanged, Preempted }
tuckˑregistryˑIntersection :: struct {
	tuckTag: tuckˑregistryˑIntersectionKind,
	to: u8,
	source: u8,
}

latesttuckˑregistryˑIntersection: tuckˑregistryˑIntersection

raise_tuckˑregistryˑIntersection_PhaseChanged :: proc(to: u8) {
	latesttuckˑregistryˑIntersection = tuckˑregistryˑIntersection{tuckTag = .PhaseChanged, to = to}
	tuckˑfnˑIntersection_PhaseChanged(to)
}

raise_tuckˑregistryˑIntersection_Preempted :: proc(source: u8) {
	latesttuckˑregistryˑIntersection = tuckˑregistryˑIntersection{tuckTag = .Preempted, source = source}
	tuckˑfnˑIntersection_Preempted(source)
}


tuckˑtypeˑPhase :: enum { NorthSouth, NsClearing, EastWest, EwClearing }
canTransition_tuckˑtypeˑPhase :: proc(frm: tuckˑtypeˑPhase, to: tuckˑtypeˑPhase) -> bool {
	switch frm {
	case .NorthSouth: return to == .NsClearing
	case .NsClearing: return to == .EastWest
	case .EastWest: return to == .EwClearing
	case .EwClearing: return to == .NorthSouth
	}
	return false
}
transitionTo_tuckˑtypeˑPhase :: proc(self: ^tuckˑtypeˑPhase, target: tuckˑtypeˑPhase) {
	assert(canTransition_tuckˑtypeˑPhase(self^, target), "Invalid transition")
	self^ = target
}

tuckˑtypeˑDemand :: enum { quiet, northSouth, eastWest, both }

tuckˑdecisionˑnextPhase :: proc (current: tuckˑtypeˑPhase, demand: tuckˑtypeˑDemand, preempt: bool) -> tuckˑtypeˑPhase {
  switch ((((int(current) * 8) + (int(demand) * 2)) + (preempt ? 1 : 0)))
  {
  case 0, 2, 24, 25, 26, 27, 28, 29, 30, 31: return tuckˑtypeˑPhase.NorthSouth;
  case 1, 3, 4, 5, 6, 7: return tuckˑtypeˑPhase.NsClearing;
  case 8, 9, 10, 11, 12, 13, 14, 15, 16, 20: return tuckˑtypeˑPhase.EastWest;
  case: return tuckˑtypeˑPhase.EwClearing;
  }
  return {}
}

DetectorTag :: enum { Detector_is_tuckˑobjectˑCameraDetector, Detector_is_tuckˑobjectˑLoopDetector }

Detector :: struct {
	tag: DetectorTag,
	tuckˑobjectˑCameraDetectorVal: tuckˑobjectˑCameraDetector,
	tuckˑobjectˑLoopDetectorVal: tuckˑobjectˑLoopDetector,
}

tuckˑobjectˑLoopDetector :: struct {
	lane: int,
}

tuckˑobjectˑLoopDetectorˑtuckˑfnˑhealthy :: proc (self: ^tuckˑobjectˑLoopDetector) -> bool {
  return true
}

tuckˑobjectˑLoopDetectorˑreads :: proc (self: ^tuckˑobjectˑLoopDetector) -> int {
  return self^.lane
}


tuckˑobjectˑCameraDetector :: struct {
	confidence: u8,
}

tuckˑobjectˑCameraDetectorˑtuckˑfnˑhealthy :: proc (self: ^tuckˑobjectˑCameraDetector) -> bool {
  return true
}

tuckˑobjectˑCameraDetectorˑreads :: proc (self: ^tuckˑobjectˑCameraDetector) -> int {
  if (self^.confidence > 80) {
      return 3
  }
  return 0
}


tuckˑactorˑSignalsMsgKind :: enum { msgSense }
tuckˑactorˑSignalsMsg :: struct {
	tuckTag: tuckˑactorˑSignalsMsgKind,
	demand: tuckˑtypeˑDemand,
	preempt: bool,
}
tuckˑactorˑSignals :: struct {
	phase: tuckˑtypeˑPhase,
	cycles: int,
	mailbox: rt.Mailbox(tuckˑactorˑSignalsMsg, 8),
}

tuckˑactorˑSignalsSingleton: tuckˑactorˑSignals

handleMsg_tuckˑactorˑSignals :: proc(self: ^tuckˑactorˑSignals, msg: tuckˑactorˑSignalsMsg) {
	switch msg.tuckTag {
	case .msgSense:
		demand := msg.demand
		preempt := msg.preempt
    tuckˑvˑwant := tuckˑdecisionˑnextPhase(self.phase, demand, preempt)
    self.phase = tuckˑvˑwant
    self.cycles = (self.cycles + 1)
	}
}

tuckˑactorˑSignalsSlot: rawptr

drain_tuckˑactorˑSignals :: proc() -> bool {
	didWork := false
	batch, n := rt.takeBatch(&tuckˑactorˑSignalsSingleton.mailbox)
	for i in 0 ..< n {
		handleMsg_tuckˑactorˑSignals(&tuckˑactorˑSignalsSingleton, batch[i])
		rt.tuckCheckWaiters()
		didWork = true
	}
	return didWork
}

sendSense_tuckˑactorˑSignals :: proc(self: ^tuckˑactorˑSignals, demand: tuckˑtypeˑDemand, preempt: bool) {
	_ = rt.enqueue(&self.mailbox, tuckˑactorˑSignalsMsg{tuckTag = .msgSense, demand = demand, preempt = preempt})
	rt.tuckNotifySend(tuckˑactorˑSignalsSlot)
}

tuckˑfnˑIntersection_PhaseChanged :: proc (to: u8) {
  tuckˑregisterˑSIGNAL_OUT_WALK_set(false)
}

tuckˑfnˑIntersection_Preempted :: proc (source: u8) {
  tuckˑregisterˑSIGNAL_OUT_NS_GREEN_set(false)
}

tuckˑtypeˑInterval :: struct {
	ticks: int,
}

tuckˑfnˑseconds :: proc (self: tuckˑtypeˑInterval) -> int {
  return (self.ticks / 10)
}

tuckˑfnˑlongEnough :: proc (span: $T, atLeast: int) -> bool {
  return (tuckˑfnˑseconds(span) >= atLeast)
}

tuckˑfnˑphaseIndex :: proc (p: tuckˑtypeˑPhase) -> int {
  switch (p)
  {
  case tuckˑtypeˑPhase.NorthSouth: return 0;
  case tuckˑtypeˑPhase.NsClearing: return 1;
  case tuckˑtypeˑPhase.EastWest: return 2;
  case tuckˑtypeˑPhase.EwClearing: return 3;
  }
  return {}
}

tuckˑfnˑpoll :: proc (d: Detector) -> tuckˑtypeˑDemand {
  tuckˑvˑbits := (proc(v: Detector) -> int {
	switch v.tag {
		case .Detector_is_tuckˑobjectˑCameraDetector:
			tmp := v.tuckˑobjectˑCameraDetectorVal
			return tuckˑobjectˑCameraDetectorˑreads(&tmp)
		case .Detector_is_tuckˑobjectˑLoopDetector:
			tmp := v.tuckˑobjectˑLoopDetectorVal
			return tuckˑobjectˑLoopDetectorˑreads(&tmp)
	}
	panic("unreachable interface tag")
})(d)
  switch (tuckˑvˑbits)
  {
  case 1: return tuckˑtypeˑDemand.northSouth;
  case 2: return tuckˑtypeˑDemand.eastWest;
  case 3: return tuckˑtypeˑDemand.both;
  case: return tuckˑtypeˑDemand.quiet;
  }
  return {}
}

tuckˑfnˑsettled :: proc () -> bool {
  return (tuckˑactorˑSignalsSingleton.cycles > 2)
}

tuckˑfnˑreport :: proc (d: Detector) {
  tuckˑvˑdemand := tuckˑfnˑpoll(d)
  sendSense_tuckˑactorˑSignals(&tuckˑactorˑSignalsSingleton, tuckˑvˑdemand, false)
  return
}

tuckˑfnˑdrive :: proc () {
  tuckˑvˑloops := tuckˑobjectˑLoopDetector{lane = 1}
  tuckˑvˑcamera := tuckˑobjectˑCameraDetector{confidence = u8(91)}
  tuckˑfnˑreport(Detector{tag = .Detector_is_tuckˑobjectˑCameraDetector, tuckˑobjectˑCameraDetectorVal = tuckˑvˑcamera})
  sendSense_tuckˑactorˑSignals(&tuckˑactorˑSignalsSingleton, tuckˑtypeˑDemand.quiet, false)
  tuckˑfnˑreport(Detector{tag = .Detector_is_tuckˑobjectˑLoopDetector, tuckˑobjectˑLoopDetectorVal = tuckˑvˑloops})
  return
}

tuckˑfnˑmain :: proc () -> int {
  tuckˑvˑclearing := tuckˑtypeˑInterval{ticks = 45}
  tuckˑvˑok := tuckˑfnˑlongEnough(tuckˑvˑclearing, 4)
  if !tuckˑvˑok {
      return 9
  }
  tuckˑfnˑdrive()
  rt.tuckWaitOn(tuckˑactorˑSignalsSlot, tuckˑfnˑsettled)
  return tuckˑfnˑphaseIndex(tuckˑactorˑSignalsSingleton.phase)
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuckˑactorˑSignalsSingleton.phase = tuckˑtypeˑPhase.NorthSouth
	tuckˑactorˑSignalsSingleton.cycles = 0
	rt.tuckAsyncInit()
	tuckˑactorˑSignalsSlot = rt.tuckStartActor(drain_tuckˑactorˑSignals)
	mainRc := tuckˑfnˑmain()
	rt.tuckDrainActors()
	rt.tuckTrackCheck()
	os.exit(mainRc)
}
