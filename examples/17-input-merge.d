module _17_input_merge;

import rt = tuck_rt;

struct TRec_title_duration_playSpeed_volume_speed(T_title, T_duration, T_playSpeed, T_volume, T_speed) {
    T_title title;
    T_duration duration;
    T_playSpeed playSpeed;
    T_volume volume;
    T_speed speed;
}

struct tuck_Episode {
    string title;
    uint duration;
    double playSpeed;
}

struct tuck_PlayerPrefs {
    long volume;
    double speed;
}

string tuck_describe(string title, long volume) {
    return title;
}

string tuck_header(tuck_Episode episode, long n) {
    return episode.title;
}

string tuck_play(tuck_Episode episode, tuck_PlayerPrefs prefs) {
    TRec_title_duration_playSpeed_volume_speed!(string, uint, double, long, double) tuck_ctx = TRec_title_duration_playSpeed_volume_speed!(string, uint, double, long, double)(title: episode.title, duration: episode.duration, playSpeed: episode.playSpeed, volume: prefs.volume, speed: prefs.speed);
    return tuck_describe(tuck_ctx.title, tuck_ctx.volume);
}

