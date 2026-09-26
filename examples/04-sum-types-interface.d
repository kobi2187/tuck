module _04_sum_types_interface;

import rt = tuck_rt;

struct tuck_type_Config {
    string url;
}

struct tuck_type_Feed {
    string title;
}

struct tuck_type_AudioPlayer {
    long volume;
}

struct tuck_type_NetworkClient {
    uint timeout;
}

struct tuck_type_Episode {
    string name;
}

struct tuck_type_Pair {
    string key;
    string val;
}

enum tuck_type_PodcastPlayerLifecycleKind { Unloaded, Loading, Ready, Error }

struct tuck_type_PodcastPlayerLifecycle_Unloaded {
    tuck_type_Config config;
}

struct tuck_type_PodcastPlayerLifecycle_Loading {
    tuck_type_Config config;
    long progress;
}

struct tuck_type_PodcastPlayerLifecycle_Ready {
    tuck_type_Config config;
    tuck_type_Feed feed;
    tuck_type_AudioPlayer audio;
}

struct tuck_type_PodcastPlayerLifecycle_Error {
    tuck_type_Config config;
    string reason;
}

struct tuck_type_PodcastPlayerLifecycle {
    tuck_type_PodcastPlayerLifecycleKind kind;
    union {
        tuck_type_PodcastPlayerLifecycle_Unloaded tuck_unloaded;
        tuck_type_PodcastPlayerLifecycle_Loading tuck_loading;
        tuck_type_PodcastPlayerLifecycle_Ready tuck_ready;
        tuck_type_PodcastPlayerLifecycle_Error tuck_error;
    }
    bool opEquals(const tuck_type_PodcastPlayerLifecycle o) const {
        if (kind != o.kind) return false;
        final switch (kind) {
        case tuck_type_PodcastPlayerLifecycleKind.Unloaded: return tuck_unloaded == o.tuck_unloaded;
        case tuck_type_PodcastPlayerLifecycleKind.Loading: return tuck_loading == o.tuck_loading;
        case tuck_type_PodcastPlayerLifecycleKind.Ready: return tuck_ready == o.tuck_ready;
        case tuck_type_PodcastPlayerLifecycleKind.Error: return tuck_error == o.tuck_error;
        }
    }
}

// interface Storable: no satisfying types

tuck_type_PodcastApp tuck_fn_loadEpisode(tuck_type_PodcastApp self, tuck_type_Episode episode) {
    return self;
}

void tuck_fn_startAudio(tuck_type_PodcastApp self) {
    return;
}

struct tuck_type_PodcastApp {
    long volume;
    uint timeout;
}

rt.TuckResult!(rt.TuckUnit) tuck_type_PodcastApp_tuck_fn_setMany(ref tuck_type_PodcastApp self, tuck_type_Pair[] pairs) {
    return typeof(return).init;
}

void tuck_type_PodcastApp_play(ref tuck_type_PodcastApp self, tuck_type_Episode episode) {
    tuck_type_PodcastApp tuckChain1 = self;
    tuckChain1 = tuck_fn_loadEpisode(tuckChain1, episode);
    tuck_fn_startAudio(tuckChain1);
}


