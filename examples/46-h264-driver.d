module _46_h264_driver;

import rt = tuck_rt;

__gshared uint* tuck_VI_CTRL = cast(uint*)(0x50000000);
enum tuck_VI_CTRL_ENABLE_SHIFT = 0;
enum tuck_VI_CTRL_FRAME_DONE_SHIFT = 1;
enum tuck_VI_CTRL_OVERRUN_SHIFT = 2;
bool tuck_VI_CTRL_ENABLE_get() {
    return (*tuck_VI_CTRL & (1u << tuck_VI_CTRL_ENABLE_SHIFT)) != 0;
}
void tuck_VI_CTRL_ENABLE_set(bool value) {
    if (value) *tuck_VI_CTRL |= (1u << tuck_VI_CTRL_ENABLE_SHIFT);
    else *tuck_VI_CTRL &= ~(1u << tuck_VI_CTRL_ENABLE_SHIFT);
}
bool tuck_VI_CTRL_FRAME_DONE_get() {
    return (*tuck_VI_CTRL & (1u << tuck_VI_CTRL_FRAME_DONE_SHIFT)) != 0;
}
bool tuck_VI_CTRL_OVERRUN_get() {
    return (*tuck_VI_CTRL & (1u << tuck_VI_CTRL_OVERRUN_SHIFT)) != 0;
}

__gshared uint* tuck_VI_DMA = cast(uint*)(0x50000010);
enum tuck_VI_DMA_ARMED_SHIFT = 0;
bool tuck_VI_DMA_ARMED_get() {
    return (*tuck_VI_DMA & (1u << tuck_VI_DMA_ARMED_SHIFT)) != 0;
}
void tuck_VI_DMA_ARMED_set(bool value) {
    if (value) *tuck_VI_DMA |= (1u << tuck_VI_DMA_ARMED_SHIFT);
    else *tuck_VI_DMA &= ~(1u << tuck_VI_DMA_ARMED_SHIFT);
}

__gshared uint* tuck_DEC_CTRL = cast(uint*)(0x50001000);
enum tuck_DEC_CTRL_START_SHIFT = 0;
enum tuck_DEC_CTRL_BUSY_SHIFT = 1;
enum tuck_DEC_CTRL_ERR_SHIFT = 2;
bool tuck_DEC_CTRL_START_get() {
    return (*tuck_DEC_CTRL & (1u << tuck_DEC_CTRL_START_SHIFT)) != 0;
}
void tuck_DEC_CTRL_START_set(bool value) {
    if (value) *tuck_DEC_CTRL |= (1u << tuck_DEC_CTRL_START_SHIFT);
    else *tuck_DEC_CTRL &= ~(1u << tuck_DEC_CTRL_START_SHIFT);
}
bool tuck_DEC_CTRL_BUSY_get() {
    return (*tuck_DEC_CTRL & (1u << tuck_DEC_CTRL_BUSY_SHIFT)) != 0;
}
bool tuck_DEC_CTRL_ERR_get() {
    return (*tuck_DEC_CTRL & (1u << tuck_DEC_CTRL_ERR_SHIFT)) != 0;
}

__gshared rt.ObjectPool!(ubyte[4096], 4) tuck_FrameBuffers;

enum tuck_type_NalKind { nonIdr, idr, sps, pps, sei }

enum tuck_type_Action { decode, configure, skip, flushThenDecode }

tuck_type_Action tuck_fn_route(tuck_type_NalKind nal, bool configured, bool midFrame) {
    switch ((((cast(long)(nal) * 4L) + (cast(long)(configured) * 2L)) + cast(long)(midFrame))) {
    case 0, 1, 16, 17, 18, 19:
        return tuck_type_Action.skip;
    case 2, 3, 4, 6:
        return tuck_type_Action.decode;
    case 5, 7:
        return tuck_type_Action.flushThenDecode;
    default:
        return tuck_type_Action.configure;
    }
    return typeof(return).init;
}

struct tuck_type_Frame {
    long width;
    long height;
    long bytes;
}

void validate_tuck_type_Frame(tuck_type_Frame self)
{
    version (tuckNoInvariants) {} else
    {
        if (!((self.width > 0L)))
            rt.tuckInvariantFailed("(self.width > 0L)", "tuck_type_Frame");
        if (!((self.height > 0L)))
            rt.tuckInvariantFailed("(self.height > 0L)", "tuck_type_Frame");
        if (!((self.width <= 1920L)))
            rt.tuckInvariantFailed("(self.width <= 1920L)", "tuck_type_Frame");
        if (!((self.height <= 1080L)))
            rt.tuckInvariantFailed("(self.height <= 1080L)", "tuck_type_Frame");
        if (!((self.bytes <= 4096L)))
            rt.tuckInvariantFailed("(self.bytes <= 4096L)", "tuck_type_Frame");
    }
}

tuck_type_Frame __validated_tuck_type_Frame(tuck_type_Frame v)
{
    validate_tuck_type_Frame(v);
    return v;
}

enum tuck_type_DecoderState { Idle, Configured, Decoding, Draining }

enum tuck_VideoKind { FrameReady, Overrun, DecodeError }

struct tuck_Video {
    tuck_VideoKind tuckTag;
    long bytes;
    long dropped;
    ubyte code;
}

__gshared tuck_Video latesttuck_Video;

void raise_tuck_Video_FrameReady(long bytes) {
    latesttuck_Video = tuck_Video(tuck_VideoKind.FrameReady, bytes: bytes);
    tuck_fn_Video_FrameReady(bytes);
}

void raise_tuck_Video_Overrun(long dropped) {
    latesttuck_Video = tuck_Video(tuck_VideoKind.Overrun, dropped: dropped);
    tuck_fn_Video_Overrun(dropped);
}

void raise_tuck_Video_DecodeError(ubyte code) {
    latesttuck_Video = tuck_Video(tuck_VideoKind.DecodeError, code: code);
    tuck_fn_Video_DecodeError(code);
}


enum tuck_type_PipelineMsgKind { msgNal, msgOverrun }

struct tuck_type_PipelineMsg {
    tuck_type_PipelineMsgKind tuckTag;
    tuck_type_NalKind nal;
    bool midFrame;
    long n;
}

struct tuck_type_Pipeline {
    tuck_type_DecoderState state;
    long decoded;
    long dropped;
    bool configured;
    rt.Mailbox!(tuck_type_PipelineMsg, 8) mailbox;
}

__gshared tuck_type_Pipeline tuck_type_PipelineSingleton;

shared static this() {
    tuck_type_PipelineSingleton.state = tuck_type_DecoderState.Idle;
    tuck_type_PipelineSingleton.decoded = 0L;
    tuck_type_PipelineSingleton.dropped = 0L;
    tuck_type_PipelineSingleton.configured = false;
}

void handleMsg_tuck_type_Pipeline(ref tuck_type_Pipeline self, tuck_type_PipelineMsg msg) {
    final switch (msg.tuckTag) {
        case tuck_type_PipelineMsgKind.msgNal:
            auto nal = msg.nal;
            auto midFrame = msg.midFrame;
            tuck_type_Action tuck_what = tuck_fn_route(nal, self.configured, midFrame);
            final switch (tuck_what) {
            case tuck_type_Action.configure:
                self.configured = true;
                self.state = tuck_type_DecoderState.Configured;
                break;
            case tuck_type_Action.decode:
                self.state = tuck_type_DecoderState.Decoding;
                self.decoded = (self.decoded + 1L);
                break;
            case tuck_type_Action.flushThenDecode:
                self.state = tuck_type_DecoderState.Draining;
                self.decoded = (self.decoded + 1L);
                break;
            case tuck_type_Action.skip:
                self.dropped = (self.dropped + 1L);
                break;
            }
            break;
        case tuck_type_PipelineMsgKind.msgOverrun:
            auto n = msg.n;
            self.dropped = (self.dropped + n);
            break;
    }
}

__gshared void* tuck_type_PipelineSlot;

bool drain_tuck_type_Pipeline() {
    bool did = false;
    foreach (ref msg; tuck_type_PipelineSingleton.mailbox) {
        handleMsg_tuck_type_Pipeline(tuck_type_PipelineSingleton, msg);
        rt.tuckCheckWaiters();
        did = true;
    }
    return did;
}

void sendNal_tuck_type_Pipeline(ref tuck_type_Pipeline self, tuck_type_NalKind nal, bool midFrame) {
    cast(void) rt.enqueue(self.mailbox, tuck_type_PipelineMsg(tuckTag: tuck_type_PipelineMsgKind.msgNal, nal: nal, midFrame: midFrame));
    rt.tuckNotifySend(tuck_type_PipelineSlot);
}

void sendOverrun_tuck_type_Pipeline(ref tuck_type_Pipeline self, long n) {
    cast(void) rt.enqueue(self.mailbox, tuck_type_PipelineMsg(tuckTag: tuck_type_PipelineMsgKind.msgOverrun, n: n));
    rt.tuckNotifySend(tuck_type_PipelineSlot);
}


long tuck_fn_capture(long want) {
    rt.TuckResult!(rt.PoolHandle) tuck_slot = rt.acquire(tuck_FrameBuffers);
    if (!(tuck_slot.status == rt.TuckStatus.Ok)) {
        raise_tuck_Video_Overrun(1L);
        return 0L;
    }
    tuck_VI_DMA_ARMED_set(true);
    rt.release(tuck_FrameBuffers, tuck_slot.value);
    return want;
}

void tuck_fn_Video_FrameReady(long bytes) {
    tuck_DEC_CTRL_START_set(true);
}

void tuck_fn_Video_Overrun(long dropped) {
    tuck_VI_CTRL_ENABLE_set(false);
}

void tuck_fn_Video_DecodeError(ubyte code) {
    tuck_VI_CTRL_ENABLE_set(false);
}

void tuck_fn_feed(tuck_type_NalKind nal, bool midFrame) {
    sendNal_tuck_type_Pipeline(tuck_type_PipelineSingleton, nal, midFrame);
    return;
}

bool tuck_fn_drained() {
    return ((tuck_type_PipelineSingleton.decoded + tuck_type_PipelineSingleton.dropped) >= 5L);
}

void tuck_fn_config() {
    tuck_fn_feed(tuck_type_NalKind.sps, false);
    tuck_fn_feed(tuck_type_NalKind.pps, false);
    return;
}

void tuck_fn_stream() {
    tuck_fn_config();
    tuck_fn_feed(tuck_type_NalKind.idr, false);
    tuck_fn_feed(tuck_type_NalKind.nonIdr, false);
    tuck_fn_feed(tuck_type_NalKind.nonIdr, false);
    tuck_fn_feed(tuck_type_NalKind.sei, false);
    tuck_fn_feed(tuck_type_NalKind.idr, true);
    return;
}

long tuck_fn_main() {
    tuck_type_Frame tuck_f = __validated_tuck_type_Frame(tuck_type_Frame(width: 1920L, height: 1080L, bytes: 4096L));
    tuck_fn_stream();
    rt.tuckWaitOn(tuck_type_PipelineSlot, &tuck_fn_drained);
    return ((tuck_type_PipelineSingleton.decoded * 10L) + tuck_type_PipelineSingleton.dropped);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    tuck_type_PipelineSlot = rt.tuckStartActor(&drain_tuck_type_Pipeline);
    auto mainRc = tuck_fn_main();
    rt.tuckDrainActors();
    return cast(int) mainRc;
}
