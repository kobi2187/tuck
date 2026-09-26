module _18_alias;

import rt = tuck_rt;
import std.stdio : writeln, stderr;

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

void tuck_fn_playTrack(T)(T payload) {
    stderr.writeln("TUCK PENDING: tuck_fn_playTrack invoked (not implemented)");
}

void tuck_fn_main() {
    TRec_trackId_title_durationMs!(long, string, long) tuck_externalTrack = TRec_trackId_title_durationMs!(long, string, long)(trackId: 42L, title: "Slow Jam", durationMs: 215000L);
    TRec_id_name_length!(long, string, long) tuck_playerInput = TRec_id_name_length!(long, string, long)(id: tuck_externalTrack.trackId, name: tuck_externalTrack.title, length: tuck_externalTrack.durationMs);
    tuck_fn_playTrack(tuck_playerInput);
    return;
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_fn_main();
}
