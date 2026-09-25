module _45_intersection;

import rt = tuck_rt;

__gshared uint* tuck_SIGNAL_OUT = cast(uint*)(0x40011000);
enum tuck_SIGNAL_OUT_NS_GREEN_SHIFT = 0;
enum tuck_SIGNAL_OUT_EW_GREEN_SHIFT = 1;
enum tuck_SIGNAL_OUT_WALK_SHIFT = 2;
bool tuck_SIGNAL_OUT_NS_GREEN_get() {
    return (*tuck_SIGNAL_OUT & (1u << tuck_SIGNAL_OUT_NS_GREEN_SHIFT)) != 0;
}
void tuck_SIGNAL_OUT_NS_GREEN_set(bool value) {
    if (value) *tuck_SIGNAL_OUT |= (1u << tuck_SIGNAL_OUT_NS_GREEN_SHIFT);
    else *tuck_SIGNAL_OUT &= ~(1u << tuck_SIGNAL_OUT_NS_GREEN_SHIFT);
}
bool tuck_SIGNAL_OUT_EW_GREEN_get() {
    return (*tuck_SIGNAL_OUT & (1u << tuck_SIGNAL_OUT_EW_GREEN_SHIFT)) != 0;
}
void tuck_SIGNAL_OUT_EW_GREEN_set(bool value) {
    if (value) *tuck_SIGNAL_OUT |= (1u << tuck_SIGNAL_OUT_EW_GREEN_SHIFT);
    else *tuck_SIGNAL_OUT &= ~(1u << tuck_SIGNAL_OUT_EW_GREEN_SHIFT);
}
bool tuck_SIGNAL_OUT_WALK_get() {
    return (*tuck_SIGNAL_OUT & (1u << tuck_SIGNAL_OUT_WALK_SHIFT)) != 0;
}
void tuck_SIGNAL_OUT_WALK_set(bool value) {
    if (value) *tuck_SIGNAL_OUT |= (1u << tuck_SIGNAL_OUT_WALK_SHIFT);
    else *tuck_SIGNAL_OUT &= ~(1u << tuck_SIGNAL_OUT_WALK_SHIFT);
}

__gshared uint* tuck_DETECT_IN = cast(uint*)(0x40011004);
enum tuck_DETECT_IN_NS_LOOP_SHIFT = 0;
enum tuck_DETECT_IN_EW_LOOP_SHIFT = 1;
bool tuck_DETECT_IN_NS_LOOP_get() {
    return (*tuck_DETECT_IN & (1u << tuck_DETECT_IN_NS_LOOP_SHIFT)) != 0;
}
bool tuck_DETECT_IN_EW_LOOP_get() {
    return (*tuck_DETECT_IN & (1u << tuck_DETECT_IN_EW_LOOP_SHIFT)) != 0;
}

enum tuck_IntersectionKind { PhaseChanged, Preempted }

struct tuck_Intersection {
    tuck_IntersectionKind tuckTag;
    ubyte to;
    ubyte source;
}

__gshared tuck_Intersection latesttuck_Intersection;

void raise_tuck_Intersection_PhaseChanged(ubyte to) {
    latesttuck_Intersection = tuck_Intersection(tuck_IntersectionKind.PhaseChanged, to: to);
    tuck_fn_Intersection_PhaseChanged(to);
}

void raise_tuck_Intersection_Preempted(ubyte source) {
    latesttuck_Intersection = tuck_Intersection(tuck_IntersectionKind.Preempted, source: source);
    tuck_fn_Intersection_Preempted(source);
}


enum tuck_type_Phase { NorthSouth, NsClearing, EastWest, EwClearing }

enum tuck_type_Demand { quiet, northSouth, eastWest, both }

tuck_type_Phase tuck_fn_nextPhase(tuck_type_Phase current, tuck_type_Demand demand, bool preempt) {
    switch ((((cast(long)(current) * 8L) + (cast(long)(demand) * 2L)) + cast(long)(preempt))) {
    case 0, 2, 24, 25, 26, 27, 28, 29, 30, 31:
        return tuck_type_Phase.NorthSouth;
    case 1, 3, 4, 5, 6, 7:
        return tuck_type_Phase.NsClearing;
    case 8, 9, 10, 11, 12, 13, 14, 15, 16, 20:
        return tuck_type_Phase.EastWest;
    default:
        return tuck_type_Phase.EwClearing;
    }
    return typeof(return).init;
}

enum DetectorTag { Detector_is_tuck_type_CameraDetector, Detector_is_tuck_type_LoopDetector }

struct Detector {
    DetectorTag tag;
    tuck_type_CameraDetector tuck_type_CameraDetectorVal;
    tuck_type_LoopDetector tuck_type_LoopDetectorVal;
}

struct tuck_type_LoopDetector {
    long lane;
}

bool tuck_type_LoopDetector_tuck_fn_healthy(ref tuck_type_LoopDetector self) {
    return true;
}

long tuck_type_LoopDetector_reads(ref tuck_type_LoopDetector self) {
    return self.lane;
}


struct tuck_type_CameraDetector {
    ubyte confidence;
}

bool tuck_type_CameraDetector_tuck_fn_healthy(ref tuck_type_LoopDetector self) {
    return true;
}

long tuck_type_CameraDetector_reads(ref tuck_type_CameraDetector self) {
    if ((self.confidence > 80L)) {
        return 3L;
    }
    return 0L;
}


enum tuck_type_SignalsMsgKind { msgSense }

struct tuck_type_SignalsMsg {
    tuck_type_SignalsMsgKind tuckTag;
    tuck_type_Demand demand;
    bool preempt;
}

struct tuck_type_Signals {
    tuck_type_Phase phase;
    long cycles;
    rt.Mailbox!(tuck_type_SignalsMsg, 8) mailbox;
}

__gshared tuck_type_Signals tuck_type_SignalsSingleton;

shared static this() {
    tuck_type_SignalsSingleton.phase = tuck_type_Phase.NorthSouth;
    tuck_type_SignalsSingleton.cycles = 0L;
}

void handleMsg_tuck_type_Signals(ref tuck_type_Signals self, tuck_type_SignalsMsg msg) {
    final switch (msg.tuckTag) {
        case tuck_type_SignalsMsgKind.msgSense:
            auto demand = msg.demand;
            auto preempt = msg.preempt;
            tuck_type_Phase tuck_want = tuck_fn_nextPhase(self.phase, demand, preempt);
            self.phase = tuck_want;
            self.cycles = (self.cycles + 1L);
            break;
    }
}

__gshared void* tuck_type_SignalsSlot;

bool drain_tuck_type_Signals() {
    bool did = false;
    foreach (ref msg; tuck_type_SignalsSingleton.mailbox) {
        handleMsg_tuck_type_Signals(tuck_type_SignalsSingleton, msg);
        rt.tuckCheckWaiters();
        did = true;
    }
    return did;
}

void sendSense_tuck_type_Signals(ref tuck_type_Signals self, tuck_type_Demand demand, bool preempt) {
    cast(void) rt.enqueue(self.mailbox, tuck_type_SignalsMsg(tuckTag: tuck_type_SignalsMsgKind.msgSense, demand: demand, preempt: preempt));
    rt.tuckNotifySend(tuck_type_SignalsSlot);
}


void tuck_fn_Intersection_PhaseChanged(ubyte to) {
    tuck_SIGNAL_OUT_WALK_set(false);
}

void tuck_fn_Intersection_Preempted(ubyte source) {
    tuck_SIGNAL_OUT_NS_GREEN_set(false);
}

struct tuck_type_Interval {
    long ticks;
}

long tuck_fn_seconds(tuck_type_Interval self) {
    return (self.ticks / 10L);
}

bool tuck_fn_longEnough(T)(T span, long atLeast) {
    return (tuck_fn_seconds(span) >= atLeast);
}

long tuck_fn_phaseIndex(tuck_type_Phase p) {
    final switch (p) {
    case tuck_type_Phase.NorthSouth:
        return 0L;
    case tuck_type_Phase.NsClearing:
        return 1L;
    case tuck_type_Phase.EastWest:
        return 2L;
    case tuck_type_Phase.EwClearing:
        return 3L;
    }
    return typeof(return).init;
}

tuck_type_Demand tuck_fn_poll(Detector d) {
    long tuck_bits = ((Detector v) {
    switch (v.tag) {
        case DetectorTag.Detector_is_tuck_type_CameraDetector:
            auto tmp = v.tuck_type_CameraDetectorVal;
            return tuck_type_CameraDetector_reads(tmp);
        case DetectorTag.Detector_is_tuck_type_LoopDetector:
            auto tmp = v.tuck_type_LoopDetectorVal;
            return tuck_type_LoopDetector_reads(tmp);
        default: assert(0, "unreachable interface tag");
    }
})(d);
    switch (tuck_bits) {
    case 1:
        return tuck_type_Demand.northSouth;
    case 2:
        return tuck_type_Demand.eastWest;
    case 3:
        return tuck_type_Demand.both;
    default:
        return tuck_type_Demand.quiet;
    }
    return typeof(return).init;
}

bool tuck_fn_settled() {
    return (tuck_type_SignalsSingleton.cycles > 2L);
}

void tuck_fn_report(Detector d) {
    tuck_type_Demand tuck_demand = tuck_fn_poll(d);
    sendSense_tuck_type_Signals(tuck_type_SignalsSingleton, tuck_demand, false);
    return;
}

void tuck_fn_drive() {
    tuck_type_LoopDetector tuck_loops = tuck_type_LoopDetector(lane: 1L);
    tuck_type_CameraDetector tuck_camera = tuck_type_CameraDetector(confidence: 91L);
    tuck_fn_report(Detector(DetectorTag.Detector_is_tuck_type_CameraDetector, tuck_type_CameraDetectorVal: tuck_camera));
    sendSense_tuck_type_Signals(tuck_type_SignalsSingleton, tuck_type_Demand.quiet, false);
    tuck_fn_report(Detector(DetectorTag.Detector_is_tuck_type_LoopDetector, tuck_type_LoopDetectorVal: tuck_loops));
    return;
}

long tuck_fn_main() {
    tuck_type_Interval tuck_clearing = tuck_type_Interval(ticks: 45L);
    bool tuck_ok = tuck_fn_longEnough(tuck_clearing, 4L);
    if (!tuck_ok) {
        return 9L;
    }
    tuck_fn_drive();
    rt.tuckWaitOn(tuck_type_SignalsSlot, &tuck_fn_settled);
    return tuck_fn_phaseIndex(tuck_type_SignalsSingleton.phase);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    tuck_type_SignalsSlot = rt.tuckStartActor(&drain_tuck_type_Signals);
    auto mainRc = tuck_fn_main();
    rt.tuckDrainActors();
    return cast(int) mainRc;
}
