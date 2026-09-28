module _14_task;

import rt = tuck_rt;
import std.stdio : writeln, stderr;
import http = mod_http;

struct TRec_feed(T_feed) {
    T_feed feed;
}

struct tuckˑtypeˑFeed {
    long episodes;
}

TRec_feed!(tuckˑtypeˑFeed) tuckˑfnˑparse(T)(T payload) {
    stderr.writeln("TUCK PENDING: parse invoked (not implemented)");
    return typeof(return).init;
}


rt.TuckResult!(TRec_feed!(tuckˑtypeˑFeed)) tuckˑtaskˑfetchFeed(string url) {
    rt.TuckResult!(http.TRec_http_body!(string)) tuckˑvˑresp = http.tuckˑfnˑget(url);
    if ((tuckˑvˑresp.status == rt.TuckStatus.Ok)) {
        return rt.tok(tuckˑfnˑparse(tuckˑvˑresp.value.body));
    }
    return rt.terr!(TRec_feed!(tuckˑtypeˑFeed))(cast(ushort)(tuckˑvˑresp.err));
}

