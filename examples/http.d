module http;

import rt = tuck_rt;
import std.stdio : writeln, stderr;

struct TRec_body(T_body) {
    T_body body;
}

enum tuckˑtypeˑHttpError { Unreachable, BadStatus }

rt.TuckResult!(TRec_body!(string)) tuckˑfnˑget(T0)(T0 p0) {
    stderr.writeln("TUCK PENDING: get invoked (not implemented)");
    return typeof(return).init;
}


