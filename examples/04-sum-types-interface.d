module _04_sum_types_interface;

import rt = tuck_rt;

struct tuck_Config {
    string url;
}

struct tuck_Feed {
    string title;
}

struct tuck_AudioPlayer {
    long volume;
}

struct tuck_NetworkClient {
    uint timeout;
}

struct tuck_Episode {
    string name;
}

struct tuck_Pair {
    string key;
    string val;
}

enum tuck_PodcastPlayerLifecycleKind { Unloaded, Loading, Ready, Error }

struct tuck_PodcastPlayerLifecycle_Unloaded {
    tuck_Config config;
}

struct tuck_PodcastPlayerLifecycle_Loading {
    tuck_Config config;
    long progress;
}

struct tuck_PodcastPlayerLifecycle_Ready {
    tuck_Config config;
    tuck_Feed feed;
    tuck_AudioPlayer audio;
}

struct tuck_PodcastPlayerLifecycle_Error {
    tuck_Config config;
    string reason;
}

struct tuck_PodcastPlayerLifecycle {
    tuck_PodcastPlayerLifecycleKind kind;
    union {
        tuck_PodcastPlayerLifecycle_Unloaded unloaded;
        tuck_PodcastPlayerLifecycle_Loading loading;
        tuck_PodcastPlayerLifecycle_Ready ready;
        tuck_PodcastPlayerLifecycle_Error error;
    }
}

// interface Storable: no satisfying types

tuck_PodcastApp tuck_loadEpisode(tuck_PodcastApp self, tuck_Episode episode) {
    return self;
}

void tuck_startAudio(tuck_PodcastApp self) {
    return;
}

struct tuck_PodcastApp {
    long volume;
    uint timeout;
}

rt.TuckResult!(rt.TuckUnit) tuck_PodcastApp_tuck_setMany(ref tuck_PodcastApp self, tuck_Pair[] pairs) {
    return typeof(return).init;
}

void tuck_PodcastApp_play(ref tuck_PodcastApp self, tuck_Episode episode) {
    tuck_PodcastApp tuckChain58 = self;
    tuckChain58 = tuck_loadEpisode(tuckChain58, episode);
    tuck_startAudio(tuckChain58);
}


