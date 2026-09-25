module _14_task;

import rt = tuck_rt;
import std.stdio : writeln, stderr;
import http = mod_http;

struct TRec_feed(T_feed) {
    T_feed feed;
}

struct tuck_type_Feed {
    long episodes;
}

TRec_feed!(tuck_type_Feed) tuck_fn_parse(T)(T payload) {
    stderr.writeln("TUCK PENDING: tuck_fn_parse invoked (not implemented)");
    return typeof(return).init;
}


rt.TuckResult!(TRec_feed!(tuck_type_Feed)) tuck_fn_fetchFeed(string url) {
    rt.TuckResult!(http.TRec_http_body!(string)) tuck_resp = http.tuck_fn_get(url);
    if ((tuck_resp.status == rt.TuckStatus.Ok)) {
        return rt.tok(tuck_fn_parse(tuck_resp.value.body));
    }
    return rt.terr!(TRec_feed!(tuck_type_Feed))(cast(ushort)(tuck_resp.err));
}

