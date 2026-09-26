module mod_time;

import rt = tuck_rt;

struct TRec_time_ms(T_ms) {
    T_ms ms;
}

alias tuckˑtypeˑMilliseconds = uint;

alias tuckˑtypeˑMicroseconds = uint;

alias tuckˑtypeˑSeconds = uint;

tuckˑtypeˑMilliseconds tuckˑfnˑms(uint value) {
    return tuckˑtypeˑMilliseconds(value);
}

tuckˑtypeˑMicroseconds tuckˑfnˑus(uint value) {
    return tuckˑtypeˑMicroseconds(value);
}

tuckˑtypeˑSeconds tuckˑfnˑs(uint value) {
    return tuckˑtypeˑSeconds(value);
}

TRec_time_ms!(ulong) nowMs() {
    return rt.nowMs!(TRec_time_ms!(ulong))();
}

void sleepMs(uint ms) {
    rt.sleepMs(ms);
}


