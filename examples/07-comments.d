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

TRec_status!(long) tuck_fn_fetch(T)(T payload) {
    stderr.writeln("TUCK PENDING: tuck_fn_fetch invoked (not implemented)");
    return typeof(return).init;
}


void tuck_fn_main() {
    TRec_url_timeout!(string, long) tuck_config = TRec_url_timeout!(string, long)(url: "https://api.example.com", timeout: 100L);
    TRec_status!(long) tuck_result = tuck_fn_fetch(tuck_config);
    return;
}

enum tuck_type_LightState { Off, On }

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_fn_main();
}
