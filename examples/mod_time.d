module mod_time;

import rt = tuck_rt;

struct TRec_time_ms(T_ms) {
    T_ms ms;
}

alias tuck_type_Milliseconds = uint;

alias tuck_type_Microseconds = uint;

alias tuck_type_Seconds = uint;

tuck_type_Milliseconds tuck_fn_ms(uint value) {
    return tuck_type_Milliseconds(value);
}

tuck_type_Microseconds tuck_fn_us(uint value) {
    return tuck_type_Microseconds(value);
}

tuck_type_Seconds tuck_fn_s(uint value) {
    return tuck_type_Seconds(value);
}

TRec_time_ms!(ulong) nowMs() {
    return rt.nowMs!(TRec_time_ms!(ulong))();
}

void sleepMs(uint ms) {
    rt.sleepMs(ms);
}


