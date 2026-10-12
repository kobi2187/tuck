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

void tuckˑfnˑplayTrack(T)(T payload) {
    stderr.writeln("TUCK PENDING: playTrack invoked (not implemented)");
}

void tuckˑfnˑmain() {
    TRec_trackId_title_durationMs!(long, string, long) tuckˑvˑexternalTrack = TRec_trackId_title_durationMs!(long, string, long)(trackId: 42L, title: ("Slow Jam").idup, durationMs: 215000L);
    TRec_id_name_length!(long, string, long) tuckˑvˑplayerInput = TRec_id_name_length!(long, string, long)(id: tuckˑvˑexternalTrack.trackId, name: tuckˑvˑexternalTrack.title, length: tuckˑvˑexternalTrack.durationMs);
    scope(exit) rt.tuckDrop(tuckˑvˑplayerInput.name);
    tuckˑfnˑplayTrack(tuckˑvˑplayerInput);
    return;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckLeakMark();
    tuckˑfnˑmain();
    return rt.tuckLeakCheck(0);
}
