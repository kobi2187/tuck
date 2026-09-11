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

TRec_hasNew_episodes_metadata!(bool, long, string) tuck_fetch(T)(T payload) {
    stderr.writeln("TUCK PENDING: tuck_fetch invoked (not implemented)");
    return typeof(return).init;
}

TRec_episodes!(long) tuck_parse(T)(T payload) {
    stderr.writeln("TUCK PENDING: tuck_parse invoked (not implemented)");
    return typeof(return).init;
}

TRec_episodes!(long) tuck_selectEpisodes(T)(T payload) {
    stderr.writeln("TUCK PENDING: tuck_selectEpisodes invoked (not implemented)");
    return typeof(return).init;
}

void tuck_process(T)(T payload) {
    stderr.writeln("TUCK PENDING: tuck_process invoked (not implemented)");
}

void tuck_log(T)(T payload) {
    stderr.writeln("TUCK PENDING: tuck_log invoked (not implemented)");
}

void tuck_playTrack(T)(T payload) {
    stderr.writeln("TUCK PENDING: tuck_playTrack invoked (not implemented)");
}


void tuck_main() {
    TRec_url_timeout!(string, time.tuck_Milliseconds) tuck_request = TRec_url_timeout!(string, time.tuck_Milliseconds)(url: "example.com", timeout: time.tuck_ms(5L));
    TRec_episodes!(long) tuck_response = tuck_selectEpisodes(tuck_parse(tuck_fetch(tuck_request)));
    TRec_hasNew_episodes_metadata!(bool, long, string) tuck_feed = tuck_fetch("https://example.com/feed");
    if (tuck_feed.hasNew) {
        tuck_process(tuck_feed.episodes);
    } else {
        tuck_log(tuck_feed.metadata);
    }
    TRec_trackId_title_durationMs!(long, string, long) tuck_externalTrack = TRec_trackId_title_durationMs!(long, string, long)(trackId: 101L, title: "Deep Dive", durationMs: 212000L);
    TRec_id_name_length!(long, string, long) tuck_normalizedTrack = TRec_id_name_length!(long, string, long)(id: tuck_externalTrack.trackId, name: tuck_externalTrack.title, length: tuck_externalTrack.durationMs);
    tuck_playTrack(tuck_normalizedTrack);
    return;
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
