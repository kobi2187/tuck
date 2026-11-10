module _14_task;

import rt = tuck_rt;
import std.stdio : writeln, stderr;
import tuckˑmodˑhttp = mod_http;
import tuckˑmodˑshapes_14_task = mod_shapes_14_task;

struct tuckˑtypeˑFeed {
    long episodes;
}

tuckˑmodˑshapes_14_task.TRec_feed!(tuckˑtypeˑFeed) tuckˑfnˑparse(T0)(T0 p0) {
    stderr.writeln("TUCK PENDING: parse invoked (not implemented)");
    return typeof(return).init;
}


rt.TuckResult!(tuckˑmodˑshapes_14_task.TRec_feed!(tuckˑtypeˑFeed)) tuckˑtaskˑfetchFeed(string url) {
    rt.TuckResult!(tuckˑmodˑshapes_14_task.TRec_body!(string)) tuckˑvˑresp = tuckˑmodˑhttp.tuckˑfnˑget(url);
    scope(exit) rt.tuckDrop(tuckˑvˑresp);
    if ((tuckˑvˑresp.status == rt.TuckStatus.Ok)) {
        return rt.tok(tuckˑfnˑparse(tuckˑvˑresp.value.body));
    }
    return rt.terr!(tuckˑmodˑshapes_14_task.TRec_feed!(tuckˑtypeˑFeed))(cast(ushort)(tuckˑvˑresp.err));
}

