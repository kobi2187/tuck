module _07_comments;

import rt = tuck_rt;
import std.stdio : writeln, stderr;

struct TRec_status(T_status) {
    T_status status;
}

struct TRec_url_timeout(T_url, T_timeout) {
    T_url url;
    T_timeout timeout;
}

TRec_status!(long) tuckˑfnˑfetch(T)(T payload) {
    stderr.writeln("TUCK PENDING: fetch invoked (not implemented)");
    return typeof(return).init;
}


void tuckˑfnˑmain() {
    TRec_url_timeout!(string, long) tuckˑvˑconfig = TRec_url_timeout!(string, long)(url: "https://api.example.com", timeout: 100L);
    TRec_status!(long) tuckˑvˑresult = tuckˑfnˑfetch(tuckˑvˑconfig);
    return;
}

enum tuckˑtypeˑLightState { Off, On }

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuckˑfnˑmain();
}
