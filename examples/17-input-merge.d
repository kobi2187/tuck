module _17_input_merge;

import rt = tuck_rt;

struct TRec_title_duration_playSpeed_volume_speed_57B0 {
    string title;
    uint duration;
    double playSpeed;
    long volume;
    double speed;
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
    TRec_title_duration_playSpeed_volume_speed_57B0 ctx = TRec_title_duration_playSpeed_volume_speed_57B0(title: episode.title, duration: episode.duration, playSpeed: episode.playSpeed, volume: prefs.volume, speed: prefs.speed);
    return tuck_describe(ctx.title, ctx.volume);
}

