module _20_embedded_mp3_player;

import rt = tuck_rt;

alias tuck_Hz = uint;

alias tuck_Milliseconds = uint;

enum tuck_SystemEventsKind { PlaybackStarted, PlaybackStopped, HardwareError }

struct tuck_SystemEvents {
    tuck_SystemEventsKind kind;
    ubyte code;
}

__gshared tuck_SystemEvents latesttuck_SystemEvents;

void raise_tuck_SystemEvents_PlaybackStarted() {
    latesttuck_SystemEvents = tuck_SystemEvents(tuck_SystemEventsKind.PlaybackStarted);
    tuck_SystemEvents_PlaybackStarted();
}

void raise_tuck_SystemEvents_PlaybackStopped() {
    latesttuck_SystemEvents = tuck_SystemEvents(tuck_SystemEventsKind.PlaybackStopped);
    tuck_SystemEvents_PlaybackStopped();
}

void raise_tuck_SystemEvents_HardwareError(ubyte code) {
    latesttuck_SystemEvents = tuck_SystemEvents(tuck_SystemEventsKind.HardwareError, code: code);
    tuck_SystemEvents_HardwareError(code);
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

enum tuck_PlayerStateKind { Idle, Decoding, Paused }

struct tuck_PlayerState_Decoding {
    tuck_Hz sampleRate;
}

struct tuck_PlayerState {
    tuck_PlayerStateKind kind;
    union {
        tuck_PlayerState_Decoding decoding;
    }
}

__gshared rt.ObjectPool!(ubyte[512], 4) tuck_BufferPool;

struct tuck_Volume {
    ubyte level;
}

void validate_tuck_Volume(tuck_Volume self)
{
    version (tuckNoInvariants) {} else
    {
        if (!((self.level <= 100)))
            rt.tuckInvariantFailed("(self.level <= 100)", "tuck_Volume");
    }
}

tuck_Volume __validated_tuck_Volume(tuck_Volume v)
{
    validate_tuck_Volume(v);
    return v;
}

rt.TuckResult!(rt.TuckUnit) tuck_streamReader(ubyte streamId, uint[] chunks) {
    foreach (i; chunks) {
        rt.TuckResult!(ubyte[512]) buf = rt.acquire(tuck_BufferPool);
        if (!(buf.status == rt.TuckStatus.Ok)) {
            return;
        }
        tuck_DMA1_CH3.EN = true;
        rt.release(tuck_BufferPool, buf.value);
    }
    return typeof(return).init;
}

enum tuck_DecoderMsgKind { msgPlay, msgPause, msgStop }

struct tuck_DecoderMsg {
    tuck_DecoderMsgKind kind;
    tuck_Hz rate;
}

struct tuck_Decoder {
    tuck_PlayerState state;
    tuck_Volume vol;
    rt.Mailbox!(tuck_DecoderMsg, 8) mailbox;
}

__gshared tuck_Decoder tuck_DecoderSingleton;

void handleMsg_tuck_Decoder(ref tuck_Decoder self, tuck_DecoderMsg msg) {
    final switch (msg.kind) {
        case tuck_DecoderMsgKind.msgPlay:
            auto rate = msg.rate;
            final switch (self.state.kind) {
            case tuck_PlayerStateKind.Idle:
                self.state = tuck_PlayerState(tuck_PlayerStateKind.Decoding, tuck_PlayerState_Decoding(sampleRate: rate));
                PlaybackStarted(tuck_SystemEvents.raise);
                tuck_DAC_CR.EN = true;
                break;
            case tuck_PlayerStateKind.Paused:
                self.state = tuck_PlayerState(tuck_PlayerStateKind.Decoding, tuck_PlayerState_Decoding(sampleRate: rate));
                PlaybackStarted(tuck_SystemEvents.raise);
                tuck_DAC_CR.EN = true;
                break;
            case tuck_PlayerStateKind.Decoding:
                break;
            }
            break;
        case tuck_DecoderMsgKind.msgPause:
            final switch (self.state.kind) {
            case tuck_PlayerStateKind.Decoding:
                self.state = tuck_PlayerState(tuck_PlayerStateKind.Paused);
                break;
            case tuck_PlayerStateKind.Idle:
                break;
            case tuck_PlayerStateKind.Paused:
                break;
            }
            tuck_DAC_CR.EN = false;
            break;
        case tuck_DecoderMsgKind.msgStop:
            self.state = tuck_PlayerState(tuck_PlayerStateKind.Idle);
            PlaybackStopped(tuck_SystemEvents.raise);
            tuck_DAC_CR.EN = false;
            break;
    }
}

bool drain_tuck_Decoder() {
    bool did = false;
    tuck_DecoderMsg msg;
    while (rt.dequeue(tuck_DecoderSingleton.mailbox, msg)) {
        handleMsg_tuck_Decoder(tuck_DecoderSingleton, msg);
        did = true;
    }
    return did;
}

void sendPlay_tuck_Decoder(ref tuck_Decoder self, tuck_Hz rate) {
    cast(void) rt.enqueue(self.mailbox, tuck_DecoderMsg(tuck_DecoderMsgKind.msgPlay, rate));
    rt.tuckNotifySend();
}

void sendPause_tuck_Decoder(ref tuck_Decoder self) {
    cast(void) rt.enqueue(self.mailbox, tuck_DecoderMsg(tuck_DecoderMsgKind.msgPause));
    rt.tuckNotifySend();
}

void sendStop_tuck_Decoder(ref tuck_Decoder self) {
    cast(void) rt.enqueue(self.mailbox, tuck_DecoderMsg(tuck_DecoderMsgKind.msgStop));
    rt.tuckNotifySend();
}


static assert((tuck_Volume.sizeof == 1));

void tuck_SystemEvents_PlaybackStarted() {
    tuck_DAC_CR.EN = true;
}

void tuck_SystemEvents_PlaybackStopped() {
    tuck_DAC_CR.EN = false;
}

void tuck_SystemEvents_HardwareError(ubyte code) {
    ubyte failed = code;
    tuck_DAC_CR.EN = false;
}

void tuck_main() {
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    rt.tuckStartActor(&drain_tuck_Decoder);
    tuck_main();
    rt.tuckRun();
}
