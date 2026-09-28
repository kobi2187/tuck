module _11_embedded_feature;

import rt = tuck_rt;

alias tuckˑtypeˑSafeRPM = ushort;

alias tuckˑtypeˑPacketSeq = ubyte;

alias tuckˑtypeˑErrorCount = uint;

struct tuckˑtypeˑSensorEvent {
    ubyte channel;
    ushort reading;
}

__gshared uint* tuckˑregisterˑRCC_CR = cast(uint*)(0x40021000);
enum tuckˑregisterˑRCC_CR_HSION_SHIFT = 0;
enum tuckˑregisterˑRCC_CR_HSIRDY_SHIFT = 1;
enum tuckˑregisterˑRCC_CR_HSITRIM_SHIFT = 3;
enum tuckˑregisterˑRCC_CR_HSITRIM_WIDTH = 7 - 3 + 1;
enum uint tuckˑregisterˑRCC_CR_HSITRIM_MASK = (1u << tuckˑregisterˑRCC_CR_HSITRIM_WIDTH) - 1;
bool tuckˑregisterˑRCC_CR_HSION_get() {
    return (*tuckˑregisterˑRCC_CR & (1u << tuckˑregisterˑRCC_CR_HSION_SHIFT)) != 0;
}
void tuckˑregisterˑRCC_CR_HSION_set(bool value) {
    if (value) *tuckˑregisterˑRCC_CR |= (1u << tuckˑregisterˑRCC_CR_HSION_SHIFT);
    else *tuckˑregisterˑRCC_CR &= ~(1u << tuckˑregisterˑRCC_CR_HSION_SHIFT);
}
bool tuckˑregisterˑRCC_CR_HSIRDY_get() {
    return (*tuckˑregisterˑRCC_CR & (1u << tuckˑregisterˑRCC_CR_HSIRDY_SHIFT)) != 0;
}
uint tuckˑregisterˑRCC_CR_HSITRIM_get() {
    return (*tuckˑregisterˑRCC_CR >> tuckˑregisterˑRCC_CR_HSITRIM_SHIFT) & tuckˑregisterˑRCC_CR_HSITRIM_MASK;
}
void tuckˑregisterˑRCC_CR_HSITRIM_set(uint value) {
    uint shifted = (value & tuckˑregisterˑRCC_CR_HSITRIM_MASK) << tuckˑregisterˑRCC_CR_HSITRIM_SHIFT;
    *tuckˑregisterˑRCC_CR = (*tuckˑregisterˑRCC_CR & ~(tuckˑregisterˑRCC_CR_HSITRIM_MASK << tuckˑregisterˑRCC_CR_HSITRIM_SHIFT)) | shifted;
}

void tuckˑfnˑprocessISR(tuckˑtypeˑSensorEvent event) {
}

__gshared rt.ObjectPool!(ubyte[64], 8) tuckˑpoolˑUartBuffer;

void tuckˑfnˑhandleUart() {
    rt.TuckResult!(rt.PoolHandle) tuckˑvˑbuf = rt.tuckPoolAcquire(tuckˑpoolˑUartBuffer);
    if (!(tuckˑvˑbuf.status == rt.TuckStatus.Ok)) {
        return;
    }
    rt.tuckPoolRelease(tuckˑpoolˑUartBuffer, tuckˑvˑbuf.value);
    return;
}

