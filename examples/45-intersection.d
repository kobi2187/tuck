module _45_intersection;

import rt = tuck_rt;

__gshared uint* tuckˑregisterˑSIGNAL_OUT = cast(uint*)(0x40011000);
enum tuckˑregisterˑSIGNAL_OUT_NS_GREEN_SHIFT = 0;
enum tuckˑregisterˑSIGNAL_OUT_EW_GREEN_SHIFT = 1;
enum tuckˑregisterˑSIGNAL_OUT_WALK_SHIFT = 2;
bool tuckˑregisterˑSIGNAL_OUT_NS_GREEN_get() {
    return (*tuckˑregisterˑSIGNAL_OUT & (1u << tuckˑregisterˑSIGNAL_OUT_NS_GREEN_SHIFT)) != 0;
}
void tuckˑregisterˑSIGNAL_OUT_NS_GREEN_set(bool value) {
    if (value) *tuckˑregisterˑSIGNAL_OUT |= (1u << tuckˑregisterˑSIGNAL_OUT_NS_GREEN_SHIFT);
    else *tuckˑregisterˑSIGNAL_OUT &= ~(1u << tuckˑregisterˑSIGNAL_OUT_NS_GREEN_SHIFT);
}
bool tuckˑregisterˑSIGNAL_OUT_EW_GREEN_get() {
    return (*tuckˑregisterˑSIGNAL_OUT & (1u << tuckˑregisterˑSIGNAL_OUT_EW_GREEN_SHIFT)) != 0;
}
void tuckˑregisterˑSIGNAL_OUT_EW_GREEN_set(bool value) {
    if (value) *tuckˑregisterˑSIGNAL_OUT |= (1u << tuckˑregisterˑSIGNAL_OUT_EW_GREEN_SHIFT);
    else *tuckˑregisterˑSIGNAL_OUT &= ~(1u << tuckˑregisterˑSIGNAL_OUT_EW_GREEN_SHIFT);
}
bool tuckˑregisterˑSIGNAL_OUT_WALK_get() {
    return (*tuckˑregisterˑSIGNAL_OUT & (1u << tuckˑregisterˑSIGNAL_OUT_WALK_SHIFT)) != 0;
}
void tuckˑregisterˑSIGNAL_OUT_WALK_set(bool value) {
    if (value) *tuckˑregisterˑSIGNAL_OUT |= (1u << tuckˑregisterˑSIGNAL_OUT_WALK_SHIFT);
    else *tuckˑregisterˑSIGNAL_OUT &= ~(1u << tuckˑregisterˑSIGNAL_OUT_WALK_SHIFT);
}

__gshared uint* tuckˑregisterˑDETECT_IN = cast(uint*)(0x40011004);
enum tuckˑregisterˑDETECT_IN_NS_LOOP_SHIFT = 0;
enum tuckˑregisterˑDETECT_IN_EW_LOOP_SHIFT = 1;
bool tuckˑregisterˑDETECT_IN_NS_LOOP_get() {
    return (*tuckˑregisterˑDETECT_IN & (1u << tuckˑregisterˑDETECT_IN_NS_LOOP_SHIFT)) != 0;
}
bool tuckˑregisterˑDETECT_IN_EW_LOOP_get() {
    return (*tuckˑregisterˑDETECT_IN & (1u << tuckˑregisterˑDETECT_IN_EW_LOOP_SHIFT)) != 0;
}

enum tuckˑregistryˑIntersectionKind { PhaseChanged, Preempted }

struct tuckˑregistryˑIntersection {
    tuckˑregistryˑIntersectionKind tuckTag;
    ubyte to;
    ubyte source;
}

__gshared tuckˑregistryˑIntersection latesttuckˑregistryˑIntersection;

void raise_tuckˑregistryˑIntersection_PhaseChanged(ubyte to) {
    latesttuckˑregistryˑIntersection = tuckˑregistryˑIntersection(tuckˑregistryˑIntersectionKind.PhaseChanged, to: to);
    tuckˑfnˑIntersection_PhaseChanged(to);
}

void raise_tuckˑregistryˑIntersection_Preempted(ubyte source) {
    latesttuckˑregistryˑIntersection = tuckˑregistryˑIntersection(tuckˑregistryˑIntersectionKind.Preempted, source: source);
    tuckˑfnˑIntersection_Preempted(source);
}


enum tuckˑtypeˑPhase { NorthSouth, NsClearing, EastWest, EwClearing }

enum tuckˑtypeˑDemand { quiet, northSouth, eastWest, both }

tuckˑtypeˑPhase tuckˑdecisionˑnextPhase(tuckˑtypeˑPhase current, tuckˑtypeˑDemand demand, bool preempt) {
    switch ((((cast(long)(current) * 8L) + (cast(long)(demand) * 2L)) + cast(long)(preempt))) {
    case 0, 2, 24, 25, 26, 27, 28, 29, 30, 31:
        return tuckˑtypeˑPhase.NorthSouth;
    case 1, 3, 4, 5, 6, 7:
        return tuckˑtypeˑPhase.NsClearing;
    case 8, 9, 10, 11, 12, 13, 14, 15, 16, 20:
        return tuckˑtypeˑPhase.EastWest;
    default:
        return tuckˑtypeˑPhase.EwClearing;
    }
    return typeof(return).init;
}

enum DetectorTag { Detector_is_tuckˑobjectˑCameraDetector, Detector_is_tuckˑobjectˑLoopDetector }

struct Detector {
    DetectorTag tag;
    tuckˑobjectˑCameraDetector tuckˑobjectˑCameraDetectorVal;
    tuckˑobjectˑLoopDetector tuckˑobjectˑLoopDetectorVal;
}

struct tuckˑobjectˑLoopDetector {
    long lane;
}

bool tuckˑobjectˑLoopDetectorˑtuckˑfnˑhealthy(ref tuckˑobjectˑLoopDetector self) {
    return true;
}

long tuckˑobjectˑLoopDetectorˑreads(ref tuckˑobjectˑLoopDetector self) {
    return self.lane;
}


struct tuckˑobjectˑCameraDetector {
    ubyte confidence;
}

bool tuckˑobjectˑCameraDetectorˑtuckˑfnˑhealthy(ref tuckˑobjectˑLoopDetector self) {
    return true;
}

long tuckˑobjectˑCameraDetectorˑreads(ref tuckˑobjectˑCameraDetector self) {
    if ((self.confidence > 80L)) {
        return 3L;
    }
    return 0L;
}


enum tuckˑactorˑSignalsMsgKind { msgSense }

struct tuckˑactorˑSignalsMsg {
    tuckˑactorˑSignalsMsgKind tuckTag;
    tuckˑtypeˑDemand demand;
    bool preempt;
}

struct tuckˑactorˑSignals {
    tuckˑtypeˑPhase phase;
    long cycles;
    rt.Mailbox!(tuckˑactorˑSignalsMsg, 8) mailbox;
}

__gshared tuckˑactorˑSignals tuckˑactorˑSignalsSingleton;

shared static this() {
    tuckˑactorˑSignalsSingleton.phase = tuckˑtypeˑPhase.NorthSouth;
    tuckˑactorˑSignalsSingleton.cycles = 0L;
}

void handleMsg_tuckˑactorˑSignals(ref tuckˑactorˑSignals self, tuckˑactorˑSignalsMsg msg) {
    final switch (msg.tuckTag) {
        case tuckˑactorˑSignalsMsgKind.msgSense:
            auto demand = msg.demand;
            auto preempt = msg.preempt;
            tuckˑtypeˑPhase tuckˑvˑwant = tuckˑdecisionˑnextPhase(self.phase, demand, preempt);
            self.phase = tuckˑvˑwant;
            self.cycles = (self.cycles + 1L);
            break;
    }
}

__gshared void* tuckˑactorˑSignalsSlot;

bool drain_tuckˑactorˑSignals() {
    bool did = false;
    foreach (ref msg; tuckˑactorˑSignalsSingleton.mailbox) {
        handleMsg_tuckˑactorˑSignals(tuckˑactorˑSignalsSingleton, msg);
        rt.tuckCheckWaiters();
        did = true;
    }
    return did;
}

void sendSense_tuckˑactorˑSignals(ref tuckˑactorˑSignals self, tuckˑtypeˑDemand demand, bool preempt) {
    cast(void) rt.enqueue(self.mailbox, tuckˑactorˑSignalsMsg(tuckTag: tuckˑactorˑSignalsMsgKind.msgSense, demand: demand, preempt: preempt));
    rt.tuckNotifySend(tuckˑactorˑSignalsSlot);
}


void tuckˑfnˑIntersection_PhaseChanged(ubyte to) {
    tuckˑregisterˑSIGNAL_OUT_WALK_set(false);
}

void tuckˑfnˑIntersection_Preempted(ubyte source) {
    tuckˑregisterˑSIGNAL_OUT_NS_GREEN_set(false);
}

struct tuckˑtypeˑInterval {
    long ticks;
}

long tuckˑfnˑseconds(tuckˑtypeˑInterval self) {
    return (self.ticks / 10L);
}

bool tuckˑfnˑlongEnough(T)(T span, long atLeast) {
    return (tuckˑfnˑseconds(span) >= atLeast);
}

long tuckˑfnˑphaseIndex(tuckˑtypeˑPhase p) {
    final switch (p) {
    case tuckˑtypeˑPhase.NorthSouth:
        return 0L;
    case tuckˑtypeˑPhase.NsClearing:
        return 1L;
    case tuckˑtypeˑPhase.EastWest:
        return 2L;
    case tuckˑtypeˑPhase.EwClearing:
        return 3L;
    }
    return typeof(return).init;
}

tuckˑtypeˑDemand tuckˑfnˑpoll(Detector d) {
    long tuckˑvˑbits = ((Detector v) {
    switch (v.tag) {
        case DetectorTag.Detector_is_tuckˑobjectˑCameraDetector:
            auto tmp = v.tuckˑobjectˑCameraDetectorVal;
            return tuckˑobjectˑCameraDetectorˑreads(tmp);
        case DetectorTag.Detector_is_tuckˑobjectˑLoopDetector:
            auto tmp = v.tuckˑobjectˑLoopDetectorVal;
            return tuckˑobjectˑLoopDetectorˑreads(tmp);
        default: assert(0, "unreachable interface tag");
    }
})(d);
    switch (tuckˑvˑbits) {
    case 1:
        return tuckˑtypeˑDemand.northSouth;
    case 2:
        return tuckˑtypeˑDemand.eastWest;
    case 3:
        return tuckˑtypeˑDemand.both;
    default:
        return tuckˑtypeˑDemand.quiet;
    }
    return typeof(return).init;
}

bool tuckˑfnˑsettled() {
    return (tuckˑactorˑSignalsSingleton.cycles > 2L);
}

void tuckˑfnˑreport(Detector d) {
    tuckˑtypeˑDemand tuckˑvˑdemand = tuckˑfnˑpoll(d);
    sendSense_tuckˑactorˑSignals(tuckˑactorˑSignalsSingleton, tuckˑvˑdemand, false);
    return;
}

void tuckˑfnˑdrive() {
    tuckˑobjectˑLoopDetector tuckˑvˑloops = tuckˑobjectˑLoopDetector(lane: 1L);
    tuckˑobjectˑCameraDetector tuckˑvˑcamera = tuckˑobjectˑCameraDetector(confidence: 91L);
    tuckˑfnˑreport(Detector(DetectorTag.Detector_is_tuckˑobjectˑCameraDetector, tuckˑobjectˑCameraDetectorVal: tuckˑvˑcamera));
    sendSense_tuckˑactorˑSignals(tuckˑactorˑSignalsSingleton, tuckˑtypeˑDemand.quiet, false);
    tuckˑfnˑreport(Detector(DetectorTag.Detector_is_tuckˑobjectˑLoopDetector, tuckˑobjectˑLoopDetectorVal: tuckˑvˑloops));
    return;
}

long tuckˑfnˑmain() {
    tuckˑtypeˑInterval tuckˑvˑclearing = tuckˑtypeˑInterval(ticks: 45L);
    bool tuckˑvˑok = tuckˑfnˑlongEnough(tuckˑvˑclearing, 4L);
    if (!tuckˑvˑok) {
        return 9L;
    }
    tuckˑfnˑdrive();
    rt.tuckWaitOn(tuckˑactorˑSignalsSlot, &tuckˑfnˑsettled);
    return tuckˑfnˑphaseIndex(tuckˑactorˑSignalsSingleton.phase);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    tuckˑactorˑSignalsSlot = rt.tuckStartActor(&drain_tuckˑactorˑSignals);
    auto mainRc = tuckˑfnˑmain();
    rt.tuckDrainActors();
    return cast(int) mainRc;
}
