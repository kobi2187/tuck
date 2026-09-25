module _23_units;

import rt = tuck_rt;

struct TRec_done(T_done) {
    T_done done;
}

alias tuck_type_Milliseconds = uint;

tuck_type_Milliseconds tuck_fn_ms(uint value) {
    return tuck_type_Milliseconds(value);
}

TRec_done!(bool) tuck_fn_delay(tuck_type_Milliseconds ms) {
    return TRec_done!(bool)(done: true);
}

void tuck_fn_main() {
    TRec_done!(bool) tuck_r = tuck_fn_delay(tuck_fn_ms(5L));
    return;
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_fn_main();
}
