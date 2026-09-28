module _01_data_flow;

import rt = tuck_rt;
import std.stdio : writeln, stderr;
import time = mod_time;

struct TRec_hasNew_episodes_metadata(T_hasNew, T_episodes, T_metadata) {
    T_hasNew hasNew;
    T_episodes episodes;
    T_metadata metadata;
}

struct TRec_episodes(T_episodes) {
    T_episodes episodes;
}

struct TRec_url_timeout(T_url, T_timeout) {
    T_url url;
    T_timeout timeout;
}

struct TRec_trackId_title_durationMs(T_trackId, T_title, T_durationMs) {
    T_trackId trackId;
    T_title title;
    T_durationMs durationMs;
}

struct TRec_id_name_length(T_id, T_name, T_length) {
    T_id id;
    T_name name;
    T_length length;
}

TRec_hasNew_episodes_metadata!(bool, long, string) tuckˑfnˑfetch(T)(T payload) {
    stderr.writeln("TUCK PENDING: fetch invoked (not implemented)");
    return typeof(return).init;
}

TRec_episodes!(long) tuckˑfnˑparse(T)(T payload) {
    stderr.writeln("TUCK PENDING: parse invoked (not implemented)");
    return typeof(return).init;
}

TRec_episodes!(long) tuckˑfnˑselectEpisodes(T)(T payload) {
    stderr.writeln("TUCK PENDING: selectEpisodes invoked (not implemented)");
    return typeof(return).init;
}

void tuckˑfnˑprocess(T)(T payload) {
    stderr.writeln("TUCK PENDING: process invoked (not implemented)");
}

void tuckˑfnˑlog(T)(T payload) {
    stderr.writeln("TUCK PENDING: log invoked (not implemented)");
}

void tuckˑfnˑplayTrack(T)(T payload) {
    stderr.writeln("TUCK PENDING: playTrack invoked (not implemented)");
}


void tuckˑfnˑmain() {
    TRec_url_timeout!(string, time.tuckˑtypeˑMilliseconds) tuckˑvˑrequest = TRec_url_timeout!(string, time.tuckˑtypeˑMilliseconds)(url: "example.com", timeout: time.tuckˑfnˑms(5L));
    TRec_episodes!(long) tuckˑvˑresponse = tuckˑfnˑselectEpisodes(tuckˑfnˑparse(tuckˑfnˑfetch(tuckˑvˑrequest)));
    TRec_hasNew_episodes_metadata!(bool, long, string) tuckˑvˑfeed = tuckˑfnˑfetch("https://example.com/feed");
    if (tuckˑvˑfeed.hasNew) {
        tuckˑfnˑprocess(tuckˑvˑfeed.episodes);
    } else {
        tuckˑfnˑlog(tuckˑvˑfeed.metadata);
    }
    TRec_trackId_title_durationMs!(long, string, long) tuckˑvˑexternalTrack = TRec_trackId_title_durationMs!(long, string, long)(trackId: 101L, title: "Deep Dive", durationMs: 212000L);
    TRec_id_name_length!(long, string, long) tuckˑvˑnormalizedTrack = TRec_id_name_length!(long, string, long)(id: tuckˑvˑexternalTrack.trackId, name: tuckˑvˑexternalTrack.title, length: tuckˑvˑexternalTrack.durationMs);
    tuckˑfnˑplayTrack(tuckˑvˑnormalizedTrack);
    return;
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuckˑfnˑmain();
}
