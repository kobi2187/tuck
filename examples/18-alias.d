module _18_alias;

import rt = tuck_rt;

struct TRec_trackId_title_durationMs_BF03 {
    long trackId;
    string title;
    long durationMs;
}

struct TRec_id_name_length_EE3E {
    long id;
    string name;
    long length;
}

void tuck_playTrack(long id, string name, long length) {
}

void tuck_main() {
    TRec_trackId_title_durationMs_BF03 tuck_externalTrack = TRec_trackId_title_durationMs_BF03(trackId: 42, title: "Slow Jam", durationMs: 215000);
    TRec_id_name_length_EE3E tuck_playerInput = TRec_id_name_length_EE3E(id: tuck_externalTrack.trackId, name: tuck_externalTrack.title, length: tuck_externalTrack.durationMs);
    tuck_playTrack(tuck_playerInput.id, tuck_playerInput.name, tuck_playerInput.length);
    return;
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
