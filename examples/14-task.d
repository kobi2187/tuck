module _14_task;

import rt = tuck_rt;
import std.stdio : writeln, stderr;
import http = mod_http;

struct TRec_feed(T_feed) {
    T_feed feed;
}

struct tuck_Feed {
    long episodes;
}

TRec_feed!(tuck_Feed) tuck_parse(T)(T payload) {
    stderr.writeln("TUCK PENDING: tuck_parse invoked (not implemented)");
    return typeof(return).init;
}


rt.TuckResult!(TRec_feed!(tuck_Feed)) tuck_fetchFeed(string url) {
    rt.TuckResult!(http.TRec_http_body!(string)) tuck_resp = http.tuck_get(url);
    if ((tuck_resp.status == rt.TuckStatus.Ok)) {
        return rt.tok(tuck_parse(tuck_resp.value.body));
    }
    return rt.terr!(TRec_feed!(tuck_Feed))(cast(ushort)(tuck_resp.err));
}

