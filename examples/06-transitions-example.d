module _06_transitions_example;

import rt = tuck_rt;

struct tuck_type_Config {
    string url;
}

struct tuck_type_Feed {
    string title;
}

enum tuck_type_PodcastPlayerLifecycleKind { Unloaded, Loading, Ready }

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
}

struct tuck_type_PodcastPlayerLifecycle {
    tuck_type_PodcastPlayerLifecycleKind kind;
    union {
        tuck_type_PodcastPlayerLifecycle_Unloaded tuck_unloaded;
        tuck_type_PodcastPlayerLifecycle_Loading tuck_loading;
        tuck_type_PodcastPlayerLifecycle_Ready tuck_ready;
    }
    bool opEquals(const tuck_type_PodcastPlayerLifecycle o) const {
        if (kind != o.kind) return false;
        final switch (kind) {
        case tuck_type_PodcastPlayerLifecycleKind.Unloaded: return tuck_unloaded == o.tuck_unloaded;
        case tuck_type_PodcastPlayerLifecycleKind.Loading: return tuck_loading == o.tuck_loading;
        case tuck_type_PodcastPlayerLifecycleKind.Ready: return tuck_ready == o.tuck_ready;
        }
    }
}

