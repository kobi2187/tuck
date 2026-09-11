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

TRec_status!(long) tuck_fetch(T)(T payload) {
    stderr.writeln("TUCK PENDING: tuck_fetch invoked (not implemented)");
    return typeof(return).init;
}


void tuck_main() {
    TRec_url_timeout!(string, long) tuck_config = TRec_url_timeout!(string, long)(url: "https://api.example.com", timeout: 100L);
    TRec_status!(long) tuck_result = tuck_fetch(tuck_config);
    return;
}

enum tuck_LightState { Off, On }

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
