module _46_h264_driver;

import rt = tuck_rt;

__gshared uint* tuckˑregisterˑVI_CTRL = cast(uint*)(0x50000000);
enum tuckˑregisterˑVI_CTRL_ENABLE_SHIFT = 0;
enum tuckˑregisterˑVI_CTRL_FRAME_DONE_SHIFT = 1;
enum tuckˑregisterˑVI_CTRL_OVERRUN_SHIFT = 2;
bool tuckˑregisterˑVI_CTRL_ENABLE_get() {
    return (*tuckˑregisterˑVI_CTRL & (1u << tuckˑregisterˑVI_CTRL_ENABLE_SHIFT)) != 0;
}
void tuckˑregisterˑVI_CTRL_ENABLE_set(bool value) {
    if (value) *tuckˑregisterˑVI_CTRL |= (1u << tuckˑregisterˑVI_CTRL_ENABLE_SHIFT);
    else *tuckˑregisterˑVI_CTRL &= ~(1u << tuckˑregisterˑVI_CTRL_ENABLE_SHIFT);
}
bool tuckˑregisterˑVI_CTRL_FRAME_DONE_get() {
    return (*tuckˑregisterˑVI_CTRL & (1u << tuckˑregisterˑVI_CTRL_FRAME_DONE_SHIFT)) != 0;
}
bool tuckˑregisterˑVI_CTRL_OVERRUN_get() {
    return (*tuckˑregisterˑVI_CTRL & (1u << tuckˑregisterˑVI_CTRL_OVERRUN_SHIFT)) != 0;
}

__gshared uint* tuckˑregisterˑVI_DMA = cast(uint*)(0x50000010);
enum tuckˑregisterˑVI_DMA_ARMED_SHIFT = 0;
bool tuckˑregisterˑVI_DMA_ARMED_get() {
    return (*tuckˑregisterˑVI_DMA & (1u << tuckˑregisterˑVI_DMA_ARMED_SHIFT)) != 0;
}
void tuckˑregisterˑVI_DMA_ARMED_set(bool value) {
    if (value) *tuckˑregisterˑVI_DMA |= (1u << tuckˑregisterˑVI_DMA_ARMED_SHIFT);
    else *tuckˑregisterˑVI_DMA &= ~(1u << tuckˑregisterˑVI_DMA_ARMED_SHIFT);
}

__gshared uint* tuckˑregisterˑDEC_CTRL = cast(uint*)(0x50001000);
enum tuckˑregisterˑDEC_CTRL_START_SHIFT = 0;
enum tuckˑregisterˑDEC_CTRL_BUSY_SHIFT = 1;
enum tuckˑregisterˑDEC_CTRL_ERR_SHIFT = 2;
bool tuckˑregisterˑDEC_CTRL_START_get() {
    return (*tuckˑregisterˑDEC_CTRL & (1u << tuckˑregisterˑDEC_CTRL_START_SHIFT)) != 0;
}
void tuckˑregisterˑDEC_CTRL_START_set(bool value) {
    if (value) *tuckˑregisterˑDEC_CTRL |= (1u << tuckˑregisterˑDEC_CTRL_START_SHIFT);
    else *tuckˑregisterˑDEC_CTRL &= ~(1u << tuckˑregisterˑDEC_CTRL_START_SHIFT);
}
bool tuckˑregisterˑDEC_CTRL_BUSY_get() {
    return (*tuckˑregisterˑDEC_CTRL & (1u << tuckˑregisterˑDEC_CTRL_BUSY_SHIFT)) != 0;
}
bool tuckˑregisterˑDEC_CTRL_ERR_get() {
    return (*tuckˑregisterˑDEC_CTRL & (1u << tuckˑregisterˑDEC_CTRL_ERR_SHIFT)) != 0;
}

__gshared rt.ObjectPool!(ubyte[4096], 4) tuckˑpoolˑFrameBuffers;

enum tuckˑtypeˑNalKind { nonIdr, idr, sps, pps, sei }

enum tuckˑtypeˑAction { decode, configure, skip, flushThenDecode }

tuckˑtypeˑAction tuckˑdecisionˑroute(tuckˑtypeˑNalKind nal, bool configured, bool midFrame) {
    switch ((((cast(long)(nal) * 4L) + (cast(long)(configured) * 2L)) + cast(long)(midFrame))) {
    case 0, 1, 16, 17, 18, 19:
        return tuckˑtypeˑAction.skip;
    case 2, 3, 4, 6:
        return tuckˑtypeˑAction.decode;
    case 5, 7:
        return tuckˑtypeˑAction.flushThenDecode;
    default:
        return tuckˑtypeˑAction.configure;
    }
    return typeof(return).init;
}

struct tuckˑtypeˑFrame {
    long width;
    long height;
    long bytes;
}

void validate_tuckˑtypeˑFrame(tuckˑtypeˑFrame self)
{
    version (tuckNoInvariants) {} else
    {
        if (!((self.width > 0L)))
            rt.tuckInvariantFailed("(self.width > 0L)", "tuckˑtypeˑFrame");
        if (!((self.height > 0L)))
            rt.tuckInvariantFailed("(self.height > 0L)", "tuckˑtypeˑFrame");
        if (!((self.width <= 1920L)))
            rt.tuckInvariantFailed("(self.width <= 1920L)", "tuckˑtypeˑFrame");
        if (!((self.height <= 1080L)))
            rt.tuckInvariantFailed("(self.height <= 1080L)", "tuckˑtypeˑFrame");
        if (!((self.bytes <= 4096L)))
            rt.tuckInvariantFailed("(self.bytes <= 4096L)", "tuckˑtypeˑFrame");
    }
}

tuckˑtypeˑFrame __validated_tuckˑtypeˑFrame(tuckˑtypeˑFrame v)
{
    validate_tuckˑtypeˑFrame(v);
    return v;
}

enum tuckˑtypeˑDecoderState { Idle, Configured, Decoding, Draining }

enum tuckˑregistryˑVideoKind { FrameReady, Overrun, DecodeError }

struct tuckˑregistryˑVideo {
    tuckˑregistryˑVideoKind tuckTag;
    long bytes;
    long dropped;
    ubyte code;
}

__gshared tuckˑregistryˑVideo latesttuckˑregistryˑVideo;

void raise_tuckˑregistryˑVideo_FrameReady(long bytes) {
    latesttuckˑregistryˑVideo = tuckˑregistryˑVideo(tuckˑregistryˑVideoKind.FrameReady, bytes: bytes);
    tuckˑfnˑVideo_FrameReady(bytes);
}

void raise_tuckˑregistryˑVideo_Overrun(long dropped) {
    latesttuckˑregistryˑVideo = tuckˑregistryˑVideo(tuckˑregistryˑVideoKind.Overrun, dropped: dropped);
    tuckˑfnˑVideo_Overrun(dropped);
}

void raise_tuckˑregistryˑVideo_DecodeError(ubyte code) {
    latesttuckˑregistryˑVideo = tuckˑregistryˑVideo(tuckˑregistryˑVideoKind.DecodeError, code: code);
    tuckˑfnˑVideo_DecodeError(code);
}


enum tuckˑactorˑPipelineMsgKind { msgNal, msgOverrun }

struct tuckˑactorˑPipelineMsg {
    tuckˑactorˑPipelineMsgKind tuckTag;
    tuckˑtypeˑNalKind nal;
    bool midFrame;
    long n;
}

struct tuckˑactorˑPipeline {
    tuckˑtypeˑDecoderState state;
    long decoded;
    long dropped;
    bool configured;
    rt.Mailbox!(tuckˑactorˑPipelineMsg, 8) mailbox;
}

__gshared tuckˑactorˑPipeline tuckˑactorˑPipelineSingleton;

shared static this() {
    tuckˑactorˑPipelineSingleton.state = tuckˑtypeˑDecoderState.Idle;
    tuckˑactorˑPipelineSingleton.decoded = 0L;
    tuckˑactorˑPipelineSingleton.dropped = 0L;
    tuckˑactorˑPipelineSingleton.configured = false;
}

void handleMsg_tuckˑactorˑPipeline(ref tuckˑactorˑPipeline self, tuckˑactorˑPipelineMsg msg) {
    final switch (msg.tuckTag) {
        case tuckˑactorˑPipelineMsgKind.msgNal:
            auto nal = msg.nal;
            auto midFrame = msg.midFrame;
            tuckˑtypeˑAction tuckˑvˑwhat = tuckˑdecisionˑroute(nal, self.configured, midFrame);
            final switch (tuckˑvˑwhat) {
            case tuckˑtypeˑAction.configure:
                self.configured = true;
                self.state = tuckˑtypeˑDecoderState.Configured;
                break;
            case tuckˑtypeˑAction.decode:
                self.state = tuckˑtypeˑDecoderState.Decoding;
                self.decoded = (self.decoded + 1L);
                break;
            case tuckˑtypeˑAction.flushThenDecode:
                self.state = tuckˑtypeˑDecoderState.Draining;
                self.decoded = (self.decoded + 1L);
                break;
            case tuckˑtypeˑAction.skip:
                self.dropped = (self.dropped + 1L);
                break;
            }
            break;
        case tuckˑactorˑPipelineMsgKind.msgOverrun:
            auto n = msg.n;
            self.dropped = (self.dropped + n);
            break;
    }
}

__gshared void* tuckˑactorˑPipelineSlot;

bool drain_tuckˑactorˑPipeline() {
    bool did = false;
    foreach (ref msg; tuckˑactorˑPipelineSingleton.mailbox) {
        handleMsg_tuckˑactorˑPipeline(tuckˑactorˑPipelineSingleton, msg);
        rt.tuckCheckWaiters();
        did = true;
    }
    return did;
}

void sendNal_tuckˑactorˑPipeline(ref tuckˑactorˑPipeline self, tuckˑtypeˑNalKind nal, bool midFrame) {
    cast(void) rt.enqueue(self.mailbox, tuckˑactorˑPipelineMsg(tuckTag: tuckˑactorˑPipelineMsgKind.msgNal, nal: nal, midFrame: midFrame));
    rt.tuckNotifySend(tuckˑactorˑPipelineSlot);
}

void sendOverrun_tuckˑactorˑPipeline(ref tuckˑactorˑPipeline self, long n) {
    cast(void) rt.enqueue(self.mailbox, tuckˑactorˑPipelineMsg(tuckTag: tuckˑactorˑPipelineMsgKind.msgOverrun, n: n));
    rt.tuckNotifySend(tuckˑactorˑPipelineSlot);
}


long tuckˑfnˑcapture(long want) {
    rt.TuckResult!(rt.PoolHandle) tuckˑvˑslot = rt.tuckPoolAcquire(tuckˑpoolˑFrameBuffers);
    if (!(tuckˑvˑslot.status == rt.TuckStatus.Ok)) {
        raise_tuckˑregistryˑVideo_Overrun(1L);
        return 0L;
    }
    tuckˑregisterˑVI_DMA_ARMED_set(true);
    rt.tuckPoolRelease(tuckˑpoolˑFrameBuffers, tuckˑvˑslot.value);
    return want;
}

void tuckˑfnˑVideo_FrameReady(long bytes) {
    tuckˑregisterˑDEC_CTRL_START_set(true);
}

void tuckˑfnˑVideo_Overrun(long dropped) {
    tuckˑregisterˑVI_CTRL_ENABLE_set(false);
}

void tuckˑfnˑVideo_DecodeError(ubyte code) {
    tuckˑregisterˑVI_CTRL_ENABLE_set(false);
}

void tuckˑfnˑfeed(tuckˑtypeˑNalKind nal, bool midFrame) {
    sendNal_tuckˑactorˑPipeline(tuckˑactorˑPipelineSingleton, nal, midFrame);
    return;
}

bool tuckˑfnˑdrained() {
    return ((tuckˑactorˑPipelineSingleton.decoded + tuckˑactorˑPipelineSingleton.dropped) >= 5L);
}

void tuckˑfnˑconfig() {
    tuckˑfnˑfeed(tuckˑtypeˑNalKind.sps, false);
    tuckˑfnˑfeed(tuckˑtypeˑNalKind.pps, false);
    return;
}

void tuckˑfnˑstream() {
    tuckˑfnˑconfig();
    tuckˑfnˑfeed(tuckˑtypeˑNalKind.idr, false);
    tuckˑfnˑfeed(tuckˑtypeˑNalKind.nonIdr, false);
    tuckˑfnˑfeed(tuckˑtypeˑNalKind.nonIdr, false);
    tuckˑfnˑfeed(tuckˑtypeˑNalKind.sei, false);
    tuckˑfnˑfeed(tuckˑtypeˑNalKind.idr, true);
    return;
}

long tuckˑfnˑmain() {
    tuckˑtypeˑFrame tuckˑvˑf = __validated_tuckˑtypeˑFrame(tuckˑtypeˑFrame(width: 1920L, height: 1080L, bytes: 4096L));
    tuckˑfnˑstream();
    rt.tuckWaitOn(tuckˑactorˑPipelineSlot, &tuckˑfnˑdrained);
    return ((tuckˑactorˑPipelineSingleton.decoded * 10L) + tuckˑactorˑPipelineSingleton.dropped);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    tuckˑactorˑPipelineSlot = rt.tuckStartActor(&drain_tuckˑactorˑPipeline);
    auto mainRc = tuckˑfnˑmain();
    rt.tuckDrainActors();
    return cast(int) mainRc;
}
