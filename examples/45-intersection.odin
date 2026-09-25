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
	tuck_fn_Intersection_PhaseChanged(to)
}

raise_tuck_Intersection_Preempted :: proc(source: u8) {
	latesttuck_Intersection = tuck_Intersection{tuckTag = .Preempted, source = source}
	tuck_fn_Intersection_Preempted(source)
}


tuck_type_Phase :: enum { NorthSouth, NsClearing, EastWest, EwClearing }
canTransition_tuck_type_Phase :: proc(frm: tuck_type_Phase, to: tuck_type_Phase) -> bool {
	switch frm {
	case .NorthSouth: return to == .NsClearing
	case .NsClearing: return to == .EastWest
	case .EastWest: return to == .EwClearing
	case .EwClearing: return to == .NorthSouth
	}
	return false
}
transitionTo_tuck_type_Phase :: proc(self: ^tuck_type_Phase, target: tuck_type_Phase) {
	assert(canTransition_tuck_type_Phase(self^, target), "Invalid transition")
	self^ = target
}

tuck_type_Demand :: enum { quiet, northSouth, eastWest, both }

tuck_fn_nextPhase :: proc (current: tuck_type_Phase, demand: tuck_type_Demand, preempt: bool) -> tuck_type_Phase {
  switch ((((int(current) * 8) + (int(demand) * 2)) + (preempt ? 1 : 0)))
  {
  case 0, 2, 24, 25, 26, 27, 28, 29, 30, 31: return tuck_type_Phase.NorthSouth;
  case 1, 3, 4, 5, 6, 7: return tuck_type_Phase.NsClearing;
  case 8, 9, 10, 11, 12, 13, 14, 15, 16, 20: return tuck_type_Phase.EastWest;
  case: return tuck_type_Phase.EwClearing;
  }
  return {}
}

DetectorTag :: enum { Detector_is_tuck_type_CameraDetector, Detector_is_tuck_type_LoopDetector }

Detector :: struct {
	tag: DetectorTag,
	tuck_type_CameraDetectorVal: tuck_type_CameraDetector,
	tuck_type_LoopDetectorVal: tuck_type_LoopDetector,
}

tuck_type_LoopDetector :: struct {
	lane: int,
}

tuck_type_LoopDetector_tuck_fn_healthy :: proc (self: ^tuck_type_LoopDetector) -> bool {
  return true
}

tuck_type_LoopDetector_reads :: proc (self: ^tuck_type_LoopDetector) -> int {
  return self^.lane
}


tuck_type_CameraDetector :: struct {
	confidence: u8,
}

tuck_type_CameraDetector_tuck_fn_healthy :: proc (self: ^tuck_type_CameraDetector) -> bool {
  return true
}

tuck_type_CameraDetector_reads :: proc (self: ^tuck_type_CameraDetector) -> int {
  if (self^.confidence > 80) {
      return 3
  }
  return 0
}


tuck_type_SignalsMsgKind :: enum { msgSense }
tuck_type_SignalsMsg :: struct {
	tuckTag: tuck_type_SignalsMsgKind,
	demand: tuck_type_Demand,
	preempt: bool,
}
tuck_type_Signals :: struct {
	phase: tuck_type_Phase,
	cycles: int,
	mailbox: rt.Mailbox(tuck_type_SignalsMsg, 8),
}

tuck_type_SignalsSingleton: tuck_type_Signals

handleMsg_tuck_type_Signals :: proc(self: ^tuck_type_Signals, msg: tuck_type_SignalsMsg) {
	switch msg.tuckTag {
	case .msgSense:
		demand := msg.demand
		preempt := msg.preempt
    tuck_want := tuck_fn_nextPhase(self.phase, demand, preempt)
    self.phase = tuck_want
    self.cycles = (self.cycles + 1)
	}
}

tuck_type_SignalsSlot: rawptr

drain_tuck_type_Signals :: proc() -> bool {
	didWork := false
	batch, n := rt.takeBatch(&tuck_type_SignalsSingleton.mailbox)
	for i in 0 ..< n {
		handleMsg_tuck_type_Signals(&tuck_type_SignalsSingleton, batch[i])
		rt.tuckCheckWaiters()
		didWork = true
	}
	return didWork
}

sendSense_tuck_type_Signals :: proc(self: ^tuck_type_Signals, demand: tuck_type_Demand, preempt: bool) {
	_ = rt.enqueue(&self.mailbox, tuck_type_SignalsMsg{tuckTag = .msgSense, demand = demand, preempt = preempt})
	rt.tuckNotifySend(tuck_type_SignalsSlot)
}

tuck_fn_Intersection_PhaseChanged :: proc (to: u8) {
  tuck_SIGNAL_OUT_WALK_set(false)
}

tuck_fn_Intersection_Preempted :: proc (source: u8) {
  tuck_SIGNAL_OUT_NS_GREEN_set(false)
}

tuck_type_Interval :: struct {
	ticks: int,
}

tuck_fn_seconds :: proc (self: tuck_type_Interval) -> int {
  return (self.ticks / 10)
}

tuck_fn_longEnough :: proc (span: $T, atLeast: int) -> bool {
  return (tuck_fn_seconds(span) >= atLeast)
}

tuck_fn_phaseIndex :: proc (p: tuck_type_Phase) -> int {
  switch (p)
  {
  case tuck_type_Phase.NorthSouth: return 0;
  case tuck_type_Phase.NsClearing: return 1;
  case tuck_type_Phase.EastWest: return 2;
  case tuck_type_Phase.EwClearing: return 3;
  }
  return {}
}

tuck_fn_poll :: proc (d: Detector) -> tuck_type_Demand {
  tuck_bits := (proc(v: Detector) -> int {
	switch v.tag {
		case .Detector_is_tuck_type_CameraDetector:
			tmp := v.tuck_type_CameraDetectorVal
			return tuck_type_CameraDetector_reads(&tmp)
		case .Detector_is_tuck_type_LoopDetector:
			tmp := v.tuck_type_LoopDetectorVal
			return tuck_type_LoopDetector_reads(&tmp)
	}
	panic("unreachable interface tag")
})(d)
  switch (tuck_bits)
  {
  case 1: return tuck_type_Demand.northSouth;
  case 2: return tuck_type_Demand.eastWest;
  case 3: return tuck_type_Demand.both;
  case: return tuck_type_Demand.quiet;
  }
  return {}
}

tuck_fn_settled :: proc () -> bool {
  return (tuck_type_SignalsSingleton.cycles > 2)
}

tuck_fn_report :: proc (d: Detector) {
  tuck_demand := tuck_fn_poll(d)
  sendSense_tuck_type_Signals(&tuck_type_SignalsSingleton, tuck_demand, false)
  return
}

tuck_fn_drive :: proc () {
  tuck_loops := tuck_type_LoopDetector{lane = 1}
  tuck_camera := tuck_type_CameraDetector{confidence = u8(91)}
  tuck_fn_report(Detector{tag = .Detector_is_tuck_type_CameraDetector, tuck_type_CameraDetectorVal = tuck_camera})
  sendSense_tuck_type_Signals(&tuck_type_SignalsSingleton, tuck_type_Demand.quiet, false)
  tuck_fn_report(Detector{tag = .Detector_is_tuck_type_LoopDetector, tuck_type_LoopDetectorVal = tuck_loops})
  return
}

tuck_fn_main :: proc () -> int {
  tuck_clearing := tuck_type_Interval{ticks = 45}
  tuck_ok := tuck_fn_longEnough(tuck_clearing, 4)
  if !tuck_ok {
      return 9
  }
  tuck_fn_drive()
  rt.tuckWaitOn(tuck_type_SignalsSlot, tuck_fn_settled)
  return tuck_fn_phaseIndex(tuck_type_SignalsSingleton.phase)
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuck_type_SignalsSingleton.phase = tuck_type_Phase.NorthSouth
	tuck_type_SignalsSingleton.cycles = 0
	rt.tuckAsyncInit()
	tuck_type_SignalsSlot = rt.tuckStartActor(drain_tuck_type_Signals)
	mainRc := tuck_fn_main()
	rt.tuckDrainActors()
	rt.tuckTrackCheck()
	os.exit(mainRc)
}
