module mod_time;

import rt = tuck_rt;

struct TRec_time_ms_2794 {
    ulong ms;
}

alias tuck_Milliseconds = uint;

alias tuck_Microseconds = uint;

alias tuck_Seconds = uint;

tuck_Milliseconds tuck_ms(uint value) {
    return tuck_Milliseconds(value);
}

tuck_Microseconds tuck_us(uint value) {
    return tuck_Microseconds(value);
}

tuck_Seconds tuck_s(uint value) {
    return tuck_Seconds(value);
}

TRec_time_ms_2794 nowMs() {
    return rt.nowMs!(TRec_time_ms_2794)();
}

void sleepMs(uint ms) {
    rt.sleepMs(ms);
}


