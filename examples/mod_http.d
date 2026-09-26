module mod_http;

import rt = tuck_rt;
import std.stdio : writeln, stderr;

struct TRec_http_body(T_body) {
    T_body body;
}

enum tuckˑtypeˑHttpError { Unreachable, BadStatus }

rt.TuckResult!(TRec_http_body!(string)) tuckˑfnˑget(T)(T payload) {
    stderr.writeln("TUCK PENDING: get invoked (not implemented)");
    return typeof(return).init;
}


