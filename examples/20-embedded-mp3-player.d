module _20_embedded_mp3_player;

import rt = tuck_rt;

alias tuck_type_Hz = uint;

alias tuck_type_Milliseconds = uint;

enum tuck_SystemEventsKind { PlaybackStarted, PlaybackStopped, HardwareError }

struct tuck_SystemEvents {
    tuck_SystemEventsKind tuckTag;
    ubyte code;
}

__gshared tuck_SystemEvents latesttuck_SystemEvents;

void raise_tuck_SystemEvents_PlaybackStarted() {
    latesttuck_SystemEvents = tuck_SystemEvents(tuck_SystemEventsKind.PlaybackStarted);
    tuck_fn_SystemEvents_PlaybackStarted();
}

void raise_tuck_SystemEvents_PlaybackStopped() {
    latesttuck_SystemEvents = tuck_SystemEvents(tuck_SystemEventsKind.PlaybackStopped);
    tuck_fn_SystemEvents_PlaybackStopped();
}

void raise_tuck_SystemEvents_HardwareError(ubyte code) {
    latesttuck_SystemEvents = tuck_SystemEvents(tuck_SystemEventsKind.HardwareError, code: code);
    tuck_fn_SystemEvents_HardwareError(code);
}


__gshared uint* tuck_DAC_CR = cast(uint*)(0x40007400);
enum tuck_DAC_CR_EN_SHIFT = 0;
enum tuck_DAC_CR_BOFF_SHIFT = 1;
bool tuck_DAC_CR_EN_get() {
    return (*tuck_DAC_CR & (1u << tuck_DAC_CR_EN_SHIFT)) != 0;
}
void tuck_DAC_CR_EN_set(bool value) {
    if (value) *tuck_DAC_CR |= (1u << tuck_DAC_CR_EN_SHIFT);
    else *tuck_DAC_CR &= ~(1u << tuck_DAC_CR_EN_SHIFT);
}
bool tuck_DAC_CR_BOFF_get() {
    return (*tuck_DAC_CR & (1u << tuck_DAC_CR_BOFF_SHIFT)) != 0;
}
void tuck_DAC_CR_BOFF_set(bool value) {
    if (value) *tuck_DAC_CR |= (1u << tuck_DAC_CR_BOFF_SHIFT);
    else *tuck_DAC_CR &= ~(1u << tuck_DAC_CR_BOFF_SHIFT);
}

__gshared uint* tuck_DMA1_CH3 = cast(uint*)(0x40020030);
enum tuck_DMA1_CH3_EN_SHIFT = 0;
enum tuck_DMA1_CH3_TCIE_SHIFT = 1;
bool tuck_DMA1_CH3_EN_get() {
    return (*tuck_DMA1_CH3 & (1u << tuck_DMA1_CH3_EN_SHIFT)) != 0;
}
void tuck_DMA1_CH3_EN_set(bool value) {
    if (value) *tuck_DMA1_CH3 |= (1u << tuck_DMA1_CH3_EN_SHIFT);
    else *tuck_DMA1_CH3 &= ~(1u << tuck_DMA1_CH3_EN_SHIFT);
}
bool tuck_DMA1_CH3_TCIE_get() {
    return (*tuck_DMA1_CH3 & (1u << tuck_DMA1_CH3_TCIE_SHIFT)) != 0;
}
void tuck_DMA1_CH3_TCIE_set(bool value) {
    if (value) *tuck_DMA1_CH3 |= (1u << tuck_DMA1_CH3_TCIE_SHIFT);
    else *tuck_DMA1_CH3 &= ~(1u << tuck_DMA1_CH3_TCIE_SHIFT);
}

enum tuck_type_PlayerStateKind { Idle, Decoding, Paused }

struct tuck_type_PlayerState_Decoding {
    tuck_type_Hz sampleRate;
}

struct tuck_type_PlayerState {
    tuck_type_PlayerStateKind kind;
    union {
        tuck_type_PlayerState_Decoding tuck_decoding;
    }
    bool opEquals(const tuck_type_PlayerState o) const {
        if (kind != o.kind) return false;
        final switch (kind) {
        case tuck_type_PlayerStateKind.Idle: return true;
        case tuck_type_PlayerStateKind.Decoding: return tuck_decoding == o.tuck_decoding;
        case tuck_type_PlayerStateKind.Paused: return true;
        }
    }
}

__gshared rt.ObjectPool!(ubyte[512], 4) tuck_BufferPool;

struct tuck_type_Volume {
    ubyte level;
}

void validate_tuck_type_Volume(tuck_type_Volume self)
{
    version (tuckNoInvariants) {} else
    {
        if (!((self.level <= 100L)))
            rt.tuckInvariantFailed("(self.level <= 100L)", "tuck_type_Volume");
    }
}

tuck_type_Volume __validated_tuck_type_Volume(tuck_type_Volume v)
{
    validate_tuck_type_Volume(v);
    return v;
}

rt.TuckResult!(rt.TuckUnit) tuck_fn_streamReader(ubyte streamId, uint[] chunks) {
    foreach (tuck_i; chunks) {
        rt.TuckResult!(rt.PoolHandle) tuck_buf = rt.acquire(tuck_BufferPool);
        if (!(tuck_buf.status == rt.TuckStatus.Ok)) {
            return rt.tokVoid();
        }
        tuck_DMA1_CH3_EN_set(true);
        rt.release(tuck_BufferPool, tuck_buf.value);
    }
    return typeof(return).init;
}

enum tuck_type_DecoderMsgKind { msgPlay, msgPause, msgStop }

struct tuck_type_DecoderMsg {
    tuck_type_DecoderMsgKind tuckTag;
    tuck_type_Hz rate;
}

struct tuck_type_Decoder {
    tuck_type_PlayerState state;
    tuck_type_Volume vol;
    rt.Mailbox!(tuck_type_DecoderMsg, 8) mailbox;
}

__gshared tuck_type_Decoder tuck_type_DecoderSingleton;

shared static this() {
    tuck_type_DecoderSingleton.state = tuck_type_PlayerState(tuck_type_PlayerStateKind.Idle);
    tuck_type_DecoderSingleton.vol = __validated_tuck_type_Volume(tuck_type_Volume(level: 80L));
}

void handleMsg_tuck_type_Decoder(ref tuck_type_Decoder self, tuck_type_DecoderMsg msg) {
    final switch (msg.tuckTag) {
        case tuck_type_DecoderMsgKind.msgPlay:
            auto rate = msg.rate;
            final switch (self.state.kind) {
            case tuck_type_PlayerStateKind.Idle:
                self.state = tuck_type_PlayerState(kind: tuck_type_PlayerStateKind.Decoding, tuck_decoding: tuck_type_PlayerState_Decoding(sampleRate: rate));
                raise_tuck_SystemEvents_PlaybackStarted();
                tuck_DAC_CR_EN_set(true);
                break;
            case tuck_type_PlayerStateKind.Paused:
                self.state = tuck_type_PlayerState(kind: tuck_type_PlayerStateKind.Decoding, tuck_decoding: tuck_type_PlayerState_Decoding(sampleRate: rate));
                raise_tuck_SystemEvents_PlaybackStarted();
                tuck_DAC_CR_EN_set(true);
                break;
            case tuck_type_PlayerStateKind.Decoding:
                break;
            }
            break;
        case tuck_type_DecoderMsgKind.msgPause:
            final switch (self.state.kind) {
            case tuck_type_PlayerStateKind.Decoding:
                self.state = tuck_type_PlayerState(tuck_type_PlayerStateKind.Paused);
                break;
            case tuck_type_PlayerStateKind.Idle:
                break;
            case tuck_type_PlayerStateKind.Paused:
                break;
            }
            tuck_DAC_CR_EN_set(false);
            break;
        case tuck_type_DecoderMsgKind.msgStop:
            self.state = tuck_type_PlayerState(tuck_type_PlayerStateKind.Idle);
            raise_tuck_SystemEvents_PlaybackStopped();
            tuck_DAC_CR_EN_set(false);
            break;
    }
}

__gshared void* tuck_type_DecoderSlot;

bool drain_tuck_type_Decoder() {
    bool did = false;
    foreach (ref msg; tuck_type_DecoderSingleton.mailbox) {
        handleMsg_tuck_type_Decoder(tuck_type_DecoderSingleton, msg);
        rt.tuckCheckWaiters();
        did = true;
    }
    return did;
}

void sendPlay_tuck_type_Decoder(ref tuck_type_Decoder self, tuck_type_Hz rate) {
    cast(void) rt.enqueue(self.mailbox, tuck_type_DecoderMsg(tuckTag: tuck_type_DecoderMsgKind.msgPlay, rate: rate));
    rt.tuckNotifySend(tuck_type_DecoderSlot);
}

void sendPause_tuck_type_Decoder(ref tuck_type_Decoder self) {
    cast(void) rt.enqueue(self.mailbox, tuck_type_DecoderMsg(tuckTag: tuck_type_DecoderMsgKind.msgPause));
    rt.tuckNotifySend(tuck_type_DecoderSlot);
}

void sendStop_tuck_type_Decoder(ref tuck_type_Decoder self) {
    cast(void) rt.enqueue(self.mailbox, tuck_type_DecoderMsg(tuckTag: tuck_type_DecoderMsgKind.msgStop));
    rt.tuckNotifySend(tuck_type_DecoderSlot);
}


static assert((tuck_type_Volume.sizeof == 1L));

void tuck_fn_SystemEvents_PlaybackStarted() {
    tuck_DAC_CR_EN_set(true);
}

void tuck_fn_SystemEvents_PlaybackStopped() {
    tuck_DAC_CR_EN_set(false);
}

void tuck_fn_SystemEvents_HardwareError(ubyte code) {
    ubyte tuck_failed = code;
    tuck_DAC_CR_EN_set(false);
}

void tuck_fn_main() {
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    tuck_type_DecoderSlot = rt.tuckStartActor(&drain_tuck_type_Decoder);
    tuck_fn_main();
    rt.tuckRun();
    rt.tuckDrainActors();
}
