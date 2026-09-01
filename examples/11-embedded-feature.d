module _11_embedded_feature;

import rt = tuck_rt;

alias tuck_SafeRPM = ushort;

alias tuck_PacketSeq = ubyte;

alias tuck_ErrorCount = uint;

struct tuck_SensorEvent {
    ubyte channel;
    ushort reading;
}

__gshared uint* tuck_RCC_CR = cast(uint*)(0x40021000);
enum tuck_RCC_CR_HSION_SHIFT = 0;
enum tuck_RCC_CR_HSIRDY_SHIFT = 1;
enum tuck_RCC_CR_HSITRIM_SHIFT = 3;
enum tuck_RCC_CR_HSITRIM_WIDTH = 7 - 3 + 1;
enum uint tuck_RCC_CR_HSITRIM_MASK = (1u << tuck_RCC_CR_HSITRIM_WIDTH) - 1;
bool tuck_RCC_CR_HSION_get() {
    return (*tuck_RCC_CR & (1u << tuck_RCC_CR_HSION_SHIFT)) != 0;
}
void tuck_RCC_CR_HSION_set(bool value) {
    if (value) *tuck_RCC_CR |= (1u << tuck_RCC_CR_HSION_SHIFT);
    else *tuck_RCC_CR &= ~(1u << tuck_RCC_CR_HSION_SHIFT);
}
bool tuck_RCC_CR_HSIRDY_get() {
    return (*tuck_RCC_CR & (1u << tuck_RCC_CR_HSIRDY_SHIFT)) != 0;
}
uint tuck_RCC_CR_HSITRIM_get() {
    return (*tuck_RCC_CR >> tuck_RCC_CR_HSITRIM_SHIFT) & tuck_RCC_CR_HSITRIM_MASK;
}
void tuck_RCC_CR_HSITRIM_set(uint value) {
    uint shifted = (value & tuck_RCC_CR_HSITRIM_MASK) << tuck_RCC_CR_HSITRIM_SHIFT;
    *tuck_RCC_CR = (*tuck_RCC_CR & ~(tuck_RCC_CR_HSITRIM_MASK << tuck_RCC_CR_HSITRIM_SHIFT)) | shifted;
}

void tuck_processISR(tuck_SensorEvent event) {
}

__gshared rt.ObjectPool!(ubyte[64], 8) tuck_UartBuffer;

void tuck_handleUart() {
    rt.TuckResult!(ubyte[64]) buf = rt.acquire(tuck_UartBuffer);
    if (!(buf.status == rt.TuckStatus.Ok)) {
        return;
    }
    rt.release(tuck_UartBuffer, buf.value);
    return;
}

