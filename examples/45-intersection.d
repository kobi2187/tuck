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
    tuck_Intersection_PhaseChanged(to);
}

void raise_tuck_Intersection_Preempted(ubyte source) {
    latesttuck_Intersection = tuck_Intersection(tuck_IntersectionKind.Preempted, source: source);
    tuck_Intersection_Preempted(source);
}


enum tuck_Phase { NorthSouth, NsClearing, EastWest, EwClearing }

enum tuck_Demand { quiet, northSouth, eastWest, both }

tuck_Phase tuck_nextPhase(tuck_Phase current, tuck_Demand demand, bool preempt) {
    switch (cast(long)(current) * 8 + cast(long)(demand) * 2 + cast(long)(preempt)) {   // packed decision key
    case 0:
    case 2:
    case 24:
    case 25:
    case 26:
    case 27:
    case 28:
    case 29:
    case 30:
    case 31:
        return tuck_Phase.NorthSouth;
    case 1:
    case 3:
    case 4:
    case 5:
    case 6:
    case 7:
        return tuck_Phase.NsClearing;
    case 8:
    case 9:
    case 10:
    case 11:
    case 12:
    case 13:
    case 14:
    case 15:
    case 16:
    case 20:
        return tuck_Phase.EastWest;
    default: return tuck_Phase.EwClearing;
    }
}

enum DetectorTag { Detector_is_tuck_CameraDetector, Detector_is_tuck_LoopDetector }

struct Detector {
    DetectorTag tag;
    tuck_CameraDetector tuck_CameraDetectorVal;
    tuck_LoopDetector tuck_LoopDetectorVal;
}

struct tuck_LoopDetector {
    long lane;
}

bool tuck_LoopDetector_tuck_healthy(ref tuck_LoopDetector self) {
    return true;
}

long tuck_LoopDetector_reads(ref tuck_LoopDetector self) {
    return self.lane;
}


struct tuck_CameraDetector {
    ubyte confidence;
}

bool tuck_CameraDetector_tuck_healthy(ref tuck_LoopDetector self) {
    return true;
}

long tuck_CameraDetector_reads(ref tuck_CameraDetector self) {
    if ((self.confidence > 80L)) {
        return 3L;
    }
    return 0L;
}


enum tuck_SignalsMsgKind { msgSense }

struct tuck_SignalsMsg {
    tuck_SignalsMsgKind tuckTag;
    tuck_Demand demand;
    bool preempt;
}

struct tuck_Signals {
    tuck_Phase phase;
    long cycles;
    rt.Mailbox!(tuck_SignalsMsg, 8) mailbox;
}

__gshared tuck_Signals tuck_SignalsSingleton;

void handleMsg_tuck_Signals(ref tuck_Signals self, tuck_SignalsMsg msg) {
    final switch (msg.tuckTag) {
        case tuck_SignalsMsgKind.msgSense:
            auto demand = msg.demand;
            auto preempt = msg.preempt;
            tuck_Phase tuck_want = tuck_nextPhase(self.phase, demand, preempt);
            self.phase = tuck_want;
            self.cycles = (self.cycles + 1L);
            break;
    }
}

__gshared void* tuck_SignalsSlot;

bool drain_tuck_Signals() {
    bool did = false;
    tuck_SignalsMsg msg;
    while (rt.dequeue(tuck_SignalsSingleton.mailbox, msg)) {
        handleMsg_tuck_Signals(tuck_SignalsSingleton, msg);
        rt.tuckCheckWaiters();
        did = true;
    }
    return did;
}

void sendSense_tuck_Signals(ref tuck_Signals self, tuck_Demand demand, bool preempt) {
    cast(void) rt.enqueue(self.mailbox, tuck_SignalsMsg(tuckTag: tuck_SignalsMsgKind.msgSense, demand: demand, preempt: preempt));
    rt.tuckNotifySend();
}


void tuck_Intersection_PhaseChanged(ubyte to) {
    tuck_SIGNAL_OUT_WALK_set(false);
}

void tuck_Intersection_Preempted(ubyte source) {
    tuck_SIGNAL_OUT_NS_GREEN_set(false);
}

struct tuck_Interval {
    long ticks;
}

long tuck_seconds(tuck_Interval self) {
    return (self.ticks / 10L);
}

bool tuck_longEnough(T)(T span, long atLeast) {
    return (tuck_seconds(span) >= atLeast);
}

long tuck_phaseIndex(tuck_Phase p) {
    final switch (p) {
    case tuck_Phase.NorthSouth:
        return 0L;
    case tuck_Phase.NsClearing:
        return 1L;
    case tuck_Phase.EastWest:
        return 2L;
    case tuck_Phase.EwClearing:
        return 3L;
    }
    return typeof(return).init;
}

tuck_Demand tuck_poll(Detector d) {
    long tuck_bits = ((Detector v) {
    switch (v.tag) {
        case DetectorTag.Detector_is_tuck_CameraDetector:
            auto tmp = v.tuck_CameraDetectorVal;
            return tuck_CameraDetector_reads(tmp);
        case DetectorTag.Detector_is_tuck_LoopDetector:
            auto tmp = v.tuck_LoopDetectorVal;
            return tuck_LoopDetector_reads(tmp);
        default: assert(0, "unreachable interface tag");
    }
})(d);
    switch (tuck_bits) {
    case 1:
        return tuck_Demand.northSouth;
    case 2:
        return tuck_Demand.eastWest;
    case 3:
        return tuck_Demand.both;
    default:
        return tuck_Demand.quiet;
    }
    return typeof(return).init;
}

bool tuck_settled() {
    return (tuck_SignalsSingleton.cycles > 2L);
}

void tuck_report(Detector d) {
    tuck_Demand tuck_demand = tuck_poll(d);
    sendSense_tuck_Signals(tuck_SignalsSingleton, tuck_demand, false);
    return;
}

void tuck_drive() {
    tuck_LoopDetector tuck_loops = tuck_LoopDetector(lane: 1L);
    tuck_CameraDetector tuck_camera = tuck_CameraDetector(confidence: 91L);
    tuck_report(Detector(DetectorTag.Detector_is_tuck_CameraDetector, tuck_CameraDetectorVal: tuck_camera));
    sendSense_tuck_Signals(tuck_SignalsSingleton, tuck_Demand.quiet, false);
    tuck_report(Detector(DetectorTag.Detector_is_tuck_LoopDetector, tuck_LoopDetectorVal: tuck_loops));
    return;
}

long tuck_main() {
    tuck_Interval tuck_clearing = tuck_Interval(ticks: 45L);
    bool tuck_ok = tuck_longEnough(tuck_clearing, 4L);
    if (!tuck_ok) {
        return 9L;
    }
    tuck_drive();
    rt.tuckWaitOn(tuck_SignalsSlot, &tuck_settled);
    return tuck_phaseIndex(tuck_SignalsSingleton.phase);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    tuck_SignalsSlot = rt.tuckStartActor(&drain_tuck_Signals);
    auto mainRc = tuck_main();
    rt.tuckDrainActors();
    return cast(int) mainRc;
}
