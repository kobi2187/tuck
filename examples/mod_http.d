module mod_http;

import rt = tuck_rt;
import std.stdio : writeln, stderr;
import tuckˑmodˑshapes_14_task = mod_shapes_14_task;

enum tuckˑtypeˑHttpError { Unreachable, BadStatus }

rt.TuckResult!(tuckˑmodˑshapes_14_task.TRec_body!(string)) tuckˑfnˑget(T)(T payload) {
    stderr.writeln("TUCK PENDING: get invoked (not implemented)");
    return typeof(return).init;
}


