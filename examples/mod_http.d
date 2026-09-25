module mod_http;

import rt = tuck_rt;
import std.stdio : writeln, stderr;

struct TRec_http_body(T_body) {
    T_body body;
}

enum tuck_type_HttpError { Unreachable, BadStatus }

rt.TuckResult!(TRec_http_body!(string)) tuck_fn_get(T)(T payload) {
    stderr.writeln("TUCK PENDING: tuck_fn_get invoked (not implemented)");
    return typeof(return).init;
}


