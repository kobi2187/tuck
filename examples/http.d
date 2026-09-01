module http;

import rt = tuck_rt;
import std.stdio : writeln, stderr;

struct TRec_body_12C4 {
    string body;
}

rt.TuckResult!(TRec_body_12C4) tuck_get(T)(T payload) {
    stderr.writeln("TUCK PENDING: tuck_get invoked (not implemented)");
    return typeof(return).init;
}


