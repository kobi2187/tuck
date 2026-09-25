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
        tuck_PodcastPlayerLifecycle_Unloaded tuck_unloaded;
        tuck_PodcastPlayerLifecycle_Loading tuck_loading;
        tuck_PodcastPlayerLifecycle_Ready tuck_ready;
        tuck_PodcastPlayerLifecycle_Error tuck_error;
    }
    bool opEquals(const tuck_PodcastPlayerLifecycle o) const {
        if (kind != o.kind) return false;
        final switch (kind) {
        case tuck_PodcastPlayerLifecycleKind.Unloaded: return tuck_unloaded == o.tuck_unloaded;
        case tuck_PodcastPlayerLifecycleKind.Loading: return tuck_loading == o.tuck_loading;
        case tuck_PodcastPlayerLifecycleKind.Ready: return tuck_ready == o.tuck_ready;
        case tuck_PodcastPlayerLifecycleKind.Error: return tuck_error == o.tuck_error;
        }
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
    tuck_PodcastApp tuckChain1 = self;
    tuckChain1 = tuck_loadEpisode(tuckChain1, episode);
    tuck_startAudio(tuckChain1);
}


