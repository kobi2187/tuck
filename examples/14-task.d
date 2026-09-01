module _14_task;

import rt = tuck_rt;
import std.stdio : writeln, stderr;
import http = mod_http;

struct TRec_feed_A1A6 {
    tuck_Feed feed;
}

struct tuck_Feed {
    long episodes;
}

TRec_feed_A1A6 tuck_parse(T)(T payload) {
    stderr.writeln("TUCK PENDING: tuck_parse invoked (not implemented)");
    return typeof(return).init;
}


rt.TuckResult!(TRec_feed_A1A6) tuck_fetchFeed(string url) {
    rt.TuckResult!(http.TRec_http_body_12C4) resp = http.tuck_get(url);
    if ((resp.status == rt.TuckStatus.Ok)) {
        return tuck_parse(resp.value.body);
    }
    return rt.terr!(rt.TuckUnit)(cast(ushort)(resp.err));
}

