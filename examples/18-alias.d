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
    TRec_trackId_title_durationMs_BF03 externalTrack = TRec_trackId_title_durationMs_BF03(trackId: 42, title: "Slow Jam", durationMs: 215000);
    TRec_id_name_length_EE3E playerInput = TRec_id_name_length_EE3E(id: externalTrack.trackId, name: externalTrack.title, length: externalTrack.durationMs);
    tuck_playTrack(playerInput.id, playerInput.name, playerInput.length);
    return;
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
