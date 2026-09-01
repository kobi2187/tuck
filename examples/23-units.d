module _23_units;

import rt = tuck_rt;

struct TRec_done_7275 {
    bool done;
}

alias tuck_Milliseconds = uint;

tuck_Milliseconds tuck_ms(uint value) {
    return tuck_Milliseconds(value);
}

TRec_done_7275 tuck_delay(tuck_Milliseconds ms) {
    return TRec_done_7275(done: true);
}

void tuck_main() {
    TRec_done_7275 r = tuck_delay(tuck_ms(5));
    return;
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
