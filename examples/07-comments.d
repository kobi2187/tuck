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

TRec_status!(long) tuckˑfnˑfetch(T0)(T0 p0) {
    stderr.writeln("TUCK PENDING: fetch invoked (not implemented)");
    return typeof(return).init;
}


void tuckˑfnˑmain() {
    TRec_url_timeout!(string, long) tuckˑvˑconfig = TRec_url_timeout!(string, long)(url: ("https://api.example.com").idup, timeout: 100L);
    scope(exit) rt.tuckDrop(tuckˑvˑconfig.url);
    TRec_status!(long) tuckˑvˑresult = tuckˑfnˑfetch(tuckˑvˑconfig.url);
    return;
}

enum tuckˑtypeˑLightState { Off, On }

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckLeakMark();
    tuckˑfnˑmain();
    return rt.tuckLeakCheck(0);
}
