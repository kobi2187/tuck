module mod_time;

import rt = tuck_rt;
import tuckˑmodˑshapes_32_duration_units = mod_shapes_32_duration_units;

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

tuckˑmodˑshapes_32_duration_units.TRec_epochMs!(ulong) nowMs() {
    return rt.nowMs!(tuckˑmodˑshapes_32_duration_units.TRec_epochMs!(ulong))();
}

void sleepMs(uint ms) {
    rt.sleepMs(ms);
}


