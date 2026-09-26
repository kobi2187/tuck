module _20_embedded_mp3_player;

import rt = tuck_rt;

alias tuckˑtypeˑHz = uint;

alias tuckˑtypeˑMilliseconds = uint;

enum tuckˑregistryˑSystemEventsKind { PlaybackStarted, PlaybackStopped, HardwareError }

struct tuckˑregistryˑSystemEvents {
    tuckˑregistryˑSystemEventsKind tuckTag;
    ubyte code;
}

__gshared tuckˑregistryˑSystemEvents latesttuckˑregistryˑSystemEvents;

void raise_tuckˑregistryˑSystemEvents_PlaybackStarted() {
    latesttuckˑregistryˑSystemEvents = tuckˑregistryˑSystemEvents(tuckˑregistryˑSystemEventsKind.PlaybackStarted);
    tuckˑfnˑSystemEvents_PlaybackStarted();
}

void raise_tuckˑregistryˑSystemEvents_PlaybackStopped() {
    latesttuckˑregistryˑSystemEvents = tuckˑregistryˑSystemEvents(tuckˑregistryˑSystemEventsKind.PlaybackStopped);
    tuckˑfnˑSystemEvents_PlaybackStopped();
}

void raise_tuckˑregistryˑSystemEvents_HardwareError(ubyte code) {
    latesttuckˑregistryˑSystemEvents = tuckˑregistryˑSystemEvents(tuckˑregistryˑSystemEventsKind.HardwareError, code: code);
    tuckˑfnˑSystemEvents_HardwareError(code);
}


__gshared uint* tuckˑregisterˑDAC_CR = cast(uint*)(0x40007400);
enum tuckˑregisterˑDAC_CR_EN_SHIFT = 0;
enum tuckˑregisterˑDAC_CR_BOFF_SHIFT = 1;
bool tuckˑregisterˑDAC_CR_EN_get() {
    return (*tuckˑregisterˑDAC_CR & (1u << tuckˑregisterˑDAC_CR_EN_SHIFT)) != 0;
}
void tuckˑregisterˑDAC_CR_EN_set(bool value) {
    if (value) *tuckˑregisterˑDAC_CR |= (1u << tuckˑregisterˑDAC_CR_EN_SHIFT);
    else *tuckˑregisterˑDAC_CR &= ~(1u << tuckˑregisterˑDAC_CR_EN_SHIFT);
}
bool tuckˑregisterˑDAC_CR_BOFF_get() {
    return (*tuckˑregisterˑDAC_CR & (1u << tuckˑregisterˑDAC_CR_BOFF_SHIFT)) != 0;
}
void tuckˑregisterˑDAC_CR_BOFF_set(bool value) {
    if (value) *tuckˑregisterˑDAC_CR |= (1u << tuckˑregisterˑDAC_CR_BOFF_SHIFT);
    else *tuckˑregisterˑDAC_CR &= ~(1u << tuckˑregisterˑDAC_CR_BOFF_SHIFT);
}

__gshared uint* tuckˑregisterˑDMA1_CH3 = cast(uint*)(0x40020030);
enum tuckˑregisterˑDMA1_CH3_EN_SHIFT = 0;
enum tuckˑregisterˑDMA1_CH3_TCIE_SHIFT = 1;
bool tuckˑregisterˑDMA1_CH3_EN_get() {
    return (*tuckˑregisterˑDMA1_CH3 & (1u << tuckˑregisterˑDMA1_CH3_EN_SHIFT)) != 0;
}
void tuckˑregisterˑDMA1_CH3_EN_set(bool value) {
    if (value) *tuckˑregisterˑDMA1_CH3 |= (1u << tuckˑregisterˑDMA1_CH3_EN_SHIFT);
    else *tuckˑregisterˑDMA1_CH3 &= ~(1u << tuckˑregisterˑDMA1_CH3_EN_SHIFT);
}
bool tuckˑregisterˑDMA1_CH3_TCIE_get() {
    return (*tuckˑregisterˑDMA1_CH3 & (1u << tuckˑregisterˑDMA1_CH3_TCIE_SHIFT)) != 0;
}
void tuckˑregisterˑDMA1_CH3_TCIE_set(bool value) {
    if (value) *tuckˑregisterˑDMA1_CH3 |= (1u << tuckˑregisterˑDMA1_CH3_TCIE_SHIFT);
    else *tuckˑregisterˑDMA1_CH3 &= ~(1u << tuckˑregisterˑDMA1_CH3_TCIE_SHIFT);
}

enum tuckˑtypeˑPlayerStateKind { Idle, Decoding, Paused }

struct tuckˑtypeˑPlayerState_Decoding {
    tuckˑtypeˑHz sampleRate;
}

struct tuckˑtypeˑPlayerState {
    tuckˑtypeˑPlayerStateKind kind;
    union {
        tuckˑtypeˑPlayerState_Decoding tuckˑvariantˑdecoding;
    }
    bool opEquals(const tuckˑtypeˑPlayerState o) const {
        if (kind != o.kind) return false;
        final switch (kind) {
        case tuckˑtypeˑPlayerStateKind.Idle: return true;
        case tuckˑtypeˑPlayerStateKind.Decoding: return tuckˑvariantˑdecoding == o.tuckˑvariantˑdecoding;
        case tuckˑtypeˑPlayerStateKind.Paused: return true;
        }
    }
}

__gshared rt.ObjectPool!(ubyte[512], 4) tuckˑpoolˑBufferPool;

struct tuckˑtypeˑVolume {
    ubyte level;
}

void validate_tuckˑtypeˑVolume(tuckˑtypeˑVolume self)
{
    version (tuckNoInvariants) {} else
    {
        if (!((self.level <= 100L)))
            rt.tuckInvariantFailed("(self.level <= 100L)", "tuckˑtypeˑVolume");
    }
}

tuckˑtypeˑVolume __validated_tuckˑtypeˑVolume(tuckˑtypeˑVolume v)
{
    validate_tuckˑtypeˑVolume(v);
    return v;
}

rt.TuckResult!(rt.TuckUnit) tuckˑtaskˑstreamReader(ubyte streamId, uint[] chunks) {
    foreach (tuckˑvˑi; chunks) {
        rt.TuckResult!(rt.PoolHandle) tuckˑvˑbuf = rt.acquire(tuckˑpoolˑBufferPool);
        if (!(tuckˑvˑbuf.status == rt.TuckStatus.Ok)) {
            return rt.tokVoid();
        }
        tuckˑregisterˑDMA1_CH3_EN_set(true);
        rt.release(tuckˑpoolˑBufferPool, tuckˑvˑbuf.value);
    }
    return typeof(return).init;
}

enum tuckˑactorˑDecoderMsgKind { msgPlay, msgPause, msgStop }

struct tuckˑactorˑDecoderMsg {
    tuckˑactorˑDecoderMsgKind tuckTag;
    tuckˑtypeˑHz rate;
}

struct tuckˑactorˑDecoder {
    tuckˑtypeˑPlayerState state;
    tuckˑtypeˑVolume vol;
    rt.Mailbox!(tuckˑactorˑDecoderMsg, 8) mailbox;
}

__gshared tuckˑactorˑDecoder tuckˑactorˑDecoderSingleton;

shared static this() {
    tuckˑactorˑDecoderSingleton.state = tuckˑtypeˑPlayerState(tuckˑtypeˑPlayerStateKind.Idle);
    tuckˑactorˑDecoderSingleton.vol = __validated_tuckˑtypeˑVolume(tuckˑtypeˑVolume(level: 80L));
}

void handleMsg_tuckˑactorˑDecoder(ref tuckˑactorˑDecoder self, tuckˑactorˑDecoderMsg msg) {
    final switch (msg.tuckTag) {
        case tuckˑactorˑDecoderMsgKind.msgPlay:
            auto rate = msg.rate;
            final switch (self.state.kind) {
            case tuckˑtypeˑPlayerStateKind.Idle:
                self.state = tuckˑtypeˑPlayerState(kind: tuckˑtypeˑPlayerStateKind.Decoding, tuckˑvariantˑdecoding: tuckˑtypeˑPlayerState_Decoding(sampleRate: rate));
                raise_tuckˑregistryˑSystemEvents_PlaybackStarted();
                tuckˑregisterˑDAC_CR_EN_set(true);
                break;
            case tuckˑtypeˑPlayerStateKind.Paused:
                self.state = tuckˑtypeˑPlayerState(kind: tuckˑtypeˑPlayerStateKind.Decoding, tuckˑvariantˑdecoding: tuckˑtypeˑPlayerState_Decoding(sampleRate: rate));
                raise_tuckˑregistryˑSystemEvents_PlaybackStarted();
                tuckˑregisterˑDAC_CR_EN_set(true);
                break;
            case tuckˑtypeˑPlayerStateKind.Decoding:
                break;
            }
            break;
        case tuckˑactorˑDecoderMsgKind.msgPause:
            final switch (self.state.kind) {
            case tuckˑtypeˑPlayerStateKind.Decoding:
                self.state = tuckˑtypeˑPlayerState(tuckˑtypeˑPlayerStateKind.Paused);
                break;
            case tuckˑtypeˑPlayerStateKind.Idle:
                break;
            case tuckˑtypeˑPlayerStateKind.Paused:
                break;
            }
            tuckˑregisterˑDAC_CR_EN_set(false);
            break;
        case tuckˑactorˑDecoderMsgKind.msgStop:
            self.state = tuckˑtypeˑPlayerState(tuckˑtypeˑPlayerStateKind.Idle);
            raise_tuckˑregistryˑSystemEvents_PlaybackStopped();
            tuckˑregisterˑDAC_CR_EN_set(false);
            break;
    }
}

__gshared void* tuckˑactorˑDecoderSlot;

bool drain_tuckˑactorˑDecoder() {
    bool did = false;
    foreach (ref msg; tuckˑactorˑDecoderSingleton.mailbox) {
        handleMsg_tuckˑactorˑDecoder(tuckˑactorˑDecoderSingleton, msg);
        rt.tuckCheckWaiters();
        did = true;
    }
    return did;
}

void sendPlay_tuckˑactorˑDecoder(ref tuckˑactorˑDecoder self, tuckˑtypeˑHz rate) {
    cast(void) rt.enqueue(self.mailbox, tuckˑactorˑDecoderMsg(tuckTag: tuckˑactorˑDecoderMsgKind.msgPlay, rate: rate));
    rt.tuckNotifySend(tuckˑactorˑDecoderSlot);
}

void sendPause_tuckˑactorˑDecoder(ref tuckˑactorˑDecoder self) {
    cast(void) rt.enqueue(self.mailbox, tuckˑactorˑDecoderMsg(tuckTag: tuckˑactorˑDecoderMsgKind.msgPause));
    rt.tuckNotifySend(tuckˑactorˑDecoderSlot);
}

void sendStop_tuckˑactorˑDecoder(ref tuckˑactorˑDecoder self) {
    cast(void) rt.enqueue(self.mailbox, tuckˑactorˑDecoderMsg(tuckTag: tuckˑactorˑDecoderMsgKind.msgStop));
    rt.tuckNotifySend(tuckˑactorˑDecoderSlot);
}


static assert((tuckˑtypeˑVolume.sizeof == 1L));

void tuckˑfnˑSystemEvents_PlaybackStarted() {
    tuckˑregisterˑDAC_CR_EN_set(true);
}

void tuckˑfnˑSystemEvents_PlaybackStopped() {
    tuckˑregisterˑDAC_CR_EN_set(false);
}

void tuckˑfnˑSystemEvents_HardwareError(ubyte code) {
    ubyte tuckˑvˑfailed = code;
    tuckˑregisterˑDAC_CR_EN_set(false);
}

void tuckˑfnˑmain() {
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    tuckˑactorˑDecoderSlot = rt.tuckStartActor(&drain_tuckˑactorˑDecoder);
    tuckˑfnˑmain();
    rt.tuckRun();
    rt.tuckDrainActors();
}
