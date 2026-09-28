module _17_input_merge;

import rt = tuck_rt;

struct TRec_title_duration_playSpeed_volume_speed(T_title, T_duration, T_playSpeed, T_volume, T_speed) {
    T_title title;
    T_duration duration;
    T_playSpeed playSpeed;
    T_volume volume;
    T_speed speed;
}

struct tuckˑtypeˑEpisode {
    string title;
    uint duration;
    double playSpeed;
}

struct tuckˑtypeˑPlayerPrefs {
    long volume;
    double speed;
}

string tuckˑfnˑdescribe(string title, long volume) {
    return title;
}

string tuckˑfnˑheader(tuckˑtypeˑEpisode episode, long n) {
    return episode.title;
}

string tuckˑfnˑplay(tuckˑtypeˑEpisode episode, tuckˑtypeˑPlayerPrefs prefs) {
    TRec_title_duration_playSpeed_volume_speed!(string, uint, double, long, double) tuckˑvˑctx = TRec_title_duration_playSpeed_volume_speed!(string, uint, double, long, double)(title: episode.title, duration: episode.duration, playSpeed: episode.playSpeed, volume: prefs.volume, speed: prefs.speed);
    return tuckˑfnˑdescribe(tuckˑvˑctx.title, tuckˑvˑctx.volume);
}

