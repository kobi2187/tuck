#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"

tuck_SIGNAL_OUT := cast(^u32)(uintptr(0x40011000))
tuck_SIGNAL_OUT_NS_GREEN_SHIFT :: 0
tuck_SIGNAL_OUT_EW_GREEN_SHIFT :: 1
tuck_SIGNAL_OUT_WALK_SHIFT :: 2
tuck_SIGNAL_OUT_NS_GREEN_get :: proc() -> bool {
	return (tuck_SIGNAL_OUT^ & (u32(1) << u32(tuck_SIGNAL_OUT_NS_GREEN_SHIFT))) != 0
}
tuck_SIGNAL_OUT_NS_GREEN_set :: proc(on: bool) {
	mask := u32(1) << u32(tuck_SIGNAL_OUT_NS_GREEN_SHIFT)
	if on { tuck_SIGNAL_OUT^ |= mask } else { tuck_SIGNAL_OUT^ &~= mask }
}
tuck_SIGNAL_OUT_EW_GREEN_get :: proc() -> bool {
	return (tuck_SIGNAL_OUT^ & (u32(1) << u32(tuck_SIGNAL_OUT_EW_GREEN_SHIFT))) != 0
}
tuck_SIGNAL_OUT_EW_GREEN_set :: proc(on: bool) {
	mask := u32(1) << u32(tuck_SIGNAL_OUT_EW_GREEN_SHIFT)
	if on { tuck_SIGNAL_OUT^ |= mask } else { tuck_SIGNAL_OUT^ &~= mask }
}
tuck_SIGNAL_OUT_WALK_get :: proc() -> bool {
	return (tuck_SIGNAL_OUT^ & (u32(1) << u32(tuck_SIGNAL_OUT_WALK_SHIFT))) != 0
}
tuck_SIGNAL_OUT_WALK_set :: proc(on: bool) {
	mask := u32(1) << u32(tuck_SIGNAL_OUT_WALK_SHIFT)
	if on { tuck_SIGNAL_OUT^ |= mask } else { tuck_SIGNAL_OUT^ &~= mask }
}

tuck_DETECT_IN := cast(^u32)(uintptr(0x40011004))
tuck_DETECT_IN_NS_LOOP_SHIFT :: 0
tuck_DETECT_IN_EW_LOOP_SHIFT :: 1
tuck_DETECT_IN_NS_LOOP_get :: proc() -> bool {
	return (tuck_DETECT_IN^ & (u32(1) << u32(tuck_DETECT_IN_NS_LOOP_SHIFT))) != 0
}
tuck_DETECT_IN_EW_LOOP_get :: proc() -> bool {
	return (tuck_DETECT_IN^ & (u32(1) << u32(tuck_DETECT_IN_EW_LOOP_SHIFT))) != 0
}

tuck_IntersectionKind :: enum { PhaseChanged, Preempted }
tuck_Intersection :: struct {
	tuckTag: tuck_IntersectionKind,
	to: u8,
	source: u8,
}

latesttuck_Intersection: tuck_Intersection

raise_tuck_Intersection_PhaseChanged :: proc(to: u8) {
	latesttuck_Intersection = tuck_Intersection{tuckTag = .PhaseChanged, to = to}
	tuck_Intersection_PhaseChanged(to)
}

raise_tuck_Intersection_Preempted :: proc(source: u8) {
	latesttuck_Intersection = tuck_Intersection{tuckTag = .Preempted, source = source}
	tuck_Intersection_Preempted(source)
}


tuck_Phase :: enum { NorthSouth, NsClearing, EastWest, EwClearing }
canTransition_tuck_Phase :: proc(frm: tuck_Phase, to: tuck_Phase) -> bool {
	switch frm {
	case .NorthSouth: return to == .NsClearing
	case .NsClearing: return to == .EastWest
	case .EastWest: return to == .EwClearing
	case .EwClearing: return to == .NorthSouth
	}
	return false
}
transitionTo_tuck_Phase :: proc(self: ^tuck_Phase, target: tuck_Phase) {
	assert(canTransition_tuck_Phase(self^, target), "Invalid transition")
	self^ = target
}

tuck_Demand :: enum { quiet, northSouth, eastWest, both }

tuck_nextPhase :: proc(current: tuck_Phase, demand: tuck_Demand, preempt: bool) -> tuck_Phase {
	switch int(current) * 8 + int(demand) * 2 + (preempt ? 1 : 0) {   // packed decision key
	case 0, 2, 24, 25, 26, 27, 28, 29, 30, 31: return tuck_Phase.NorthSouth
	case 1, 3, 4, 5, 6, 7: return tuck_Phase.NsClearing
	case 8, 9, 10, 11, 12, 13, 14, 15, 16, 20: return tuck_Phase.EastWest
	case: return tuck_Phase.EwClearing
	}
}

DetectorTag :: enum { Detector_is_tuck_CameraDetector, Detector_is_tuck_LoopDetector }

Detector :: struct {
	tag: DetectorTag,
	tuck_CameraDetectorVal: tuck_CameraDetector,
	tuck_LoopDetectorVal: tuck_LoopDetector,
}

tuck_LoopDetector :: struct {
	lane: int,
}

tuck_LoopDetector_tuck_healthy :: proc (self: ^tuck_LoopDetector) -> bool {
  return true
}

tuck_LoopDetector_reads :: proc (self: ^tuck_LoopDetector) -> int {
  return self^.lane
}


tuck_CameraDetector :: struct {
	confidence: u8,
}

tuck_CameraDetector_tuck_healthy :: proc (self: ^tuck_CameraDetector) -> bool {
  return true
}

tuck_CameraDetector_reads :: proc (self: ^tuck_CameraDetector) -> int {
  if (self^.confidence > 80) {
      return 3
  }
  return 0
}


tuck_SignalsMsgKind :: enum { msgSense }
tuck_SignalsMsg :: struct {
	tuckTag: tuck_SignalsMsgKind,
	demand: tuck_Demand,
	preempt: bool,
}
tuck_Signals :: struct {
	phase: tuck_Phase,
	cycles: int,
	mailbox: rt.Mailbox(tuck_SignalsMsg, 8),
}

tuck_SignalsSingleton: tuck_Signals

handleMsg_tuck_Signals :: proc(self: ^tuck_Signals, msg: tuck_SignalsMsg) {
	switch msg.tuckTag {
	case .msgSense:
		demand := msg.demand
		preempt := msg.preempt
    tuck_want := tuck_nextPhase(self.phase, demand, preempt)
    self.phase = tuck_want
    self.cycles = (self.cycles + 1)
	}
}

tuck_SignalsSlot: rawptr

drain_tuck_Signals :: proc() -> bool {
	msg: tuck_SignalsMsg
	didWork := false
	for rt.dequeue(&tuck_SignalsSingleton.mailbox, &msg) {
		handleMsg_tuck_Signals(&tuck_SignalsSingleton, msg)
		rt.tuckCheckWaiters()
		didWork = true
	}
	return didWork
}

sendSense_tuck_Signals :: proc(self: ^tuck_Signals, demand: tuck_Demand, preempt: bool) {
	_ = rt.enqueue(&self.mailbox, tuck_SignalsMsg{tuckTag = .msgSense, demand = demand, preempt = preempt})
}

tuck_Intersection_PhaseChanged :: proc (to: u8) {
  tuck_SIGNAL_OUT_WALK_set(false)
}

tuck_Intersection_Preempted :: proc (source: u8) {
  tuck_SIGNAL_OUT_NS_GREEN_set(false)
}

tuck_Interval :: struct {
	ticks: int,
}

tuck_seconds :: proc (self: tuck_Interval) -> int {
  return (self.ticks / 10)
}

tuck_longEnough :: proc (span: $T, atLeast: int) -> bool {
  return (tuck_seconds(span) >= atLeast)
}

tuck_phaseIndex :: proc (p: tuck_Phase) -> int {
  switch (p)
  {
  case tuck_Phase.NorthSouth: return 0;
  case tuck_Phase.NsClearing: return 1;
  case tuck_Phase.EastWest: return 2;
  case tuck_Phase.EwClearing: return 3;
  }
  return {}
}

tuck_poll :: proc (d: Detector) -> tuck_Demand {
  tuck_bits := (proc(v: Detector) -> int {
	switch v.tag {
		case .Detector_is_tuck_CameraDetector:
			tmp := v.tuck_CameraDetectorVal
			return tuck_CameraDetector_reads(&tmp)
		case .Detector_is_tuck_LoopDetector:
			tmp := v.tuck_LoopDetectorVal
			return tuck_LoopDetector_reads(&tmp)
	}
	return 0
})(d)
  switch (tuck_bits)
  {
  case 1: return tuck_Demand.northSouth;
  case 2: return tuck_Demand.eastWest;
  case 3: return tuck_Demand.both;
  case: return tuck_Demand.quiet;
  }
  return {}
}

tuck_settled :: proc () -> bool {
  return (tuck_SignalsSingleton.cycles > 2)
}

tuck_report :: proc (d: Detector) {
  tuck_demand := tuck_poll(d)
  sendSense_tuck_Signals(&tuck_SignalsSingleton, tuck_demand, false)
  return
}

tuck_drive :: proc () {
  tuck_loops := tuck_LoopDetector{lane = 1}
  tuck_camera := tuck_CameraDetector{confidence = u8(91)}
  tuck_report(Detector{tag = .Detector_is_tuck_CameraDetector, tuck_CameraDetectorVal = tuck_camera})
  sendSense_tuck_Signals(&tuck_SignalsSingleton, tuck_Demand.quiet, false)
  tuck_report(Detector{tag = .Detector_is_tuck_LoopDetector, tuck_LoopDetectorVal = tuck_loops})
  return
}

tuck_main :: proc () -> int {
  tuck_clearing := tuck_Interval{ticks = 45}
  tuck_ok := tuck_longEnough(tuck_clearing, 4)
  if !tuck_ok {
      return 9
  }
  tuck_drive()
  rt.tuckWaitOn(tuck_SignalsSlot, tuck_settled)
  return tuck_phaseIndex(tuck_SignalsSingleton.phase)
}

main :: proc() {
	rt.tuckAsyncInit()
	tuck_SignalsSlot = rt.tuckStartActor(drain_tuck_Signals)
	mainRc := tuck_main()
	rt.tuckDrainActors()
	os.exit(mainRc)
}
