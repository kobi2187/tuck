module _06_transitions_example;

import rt = tuck_rt;

struct tuck_Config {
    string url;
}

struct tuck_Feed {
    string title;
}

enum tuck_PodcastPlayerLifecycleKind { Unloaded, Loading, Ready }

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
}

struct tuck_PodcastPlayerLifecycle {
    tuck_PodcastPlayerLifecycleKind kind;
    union {
        tuck_PodcastPlayerLifecycle_Unloaded tuck_unloaded;
        tuck_PodcastPlayerLifecycle_Loading tuck_loading;
        tuck_PodcastPlayerLifecycle_Ready tuck_ready;
    }
    bool opEquals(const tuck_PodcastPlayerLifecycle o) const {
        if (kind != o.kind) return false;
        final switch (kind) {
        case tuck_PodcastPlayerLifecycleKind.Unloaded: return tuck_unloaded == o.tuck_unloaded;
        case tuck_PodcastPlayerLifecycleKind.Loading: return tuck_loading == o.tuck_loading;
        case tuck_PodcastPlayerLifecycleKind.Ready: return tuck_ready == o.tuck_ready;
        }
    }
}

