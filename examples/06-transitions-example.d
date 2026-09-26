module _06_transitions_example;

import rt = tuck_rt;

struct tuckˑtypeˑConfig {
    string url;
}

struct tuckˑtypeˑFeed {
    string title;
}

enum tuckˑtypeˑPodcastPlayerLifecycleKind { Unloaded, Loading, Ready }

struct tuckˑtypeˑPodcastPlayerLifecycle_Unloaded {
    tuckˑtypeˑConfig config;
}

struct tuckˑtypeˑPodcastPlayerLifecycle_Loading {
    tuckˑtypeˑConfig config;
    long progress;
}

struct tuckˑtypeˑPodcastPlayerLifecycle_Ready {
    tuckˑtypeˑConfig config;
    tuckˑtypeˑFeed feed;
}

struct tuckˑtypeˑPodcastPlayerLifecycle {
    tuckˑtypeˑPodcastPlayerLifecycleKind kind;
    union {
        tuckˑtypeˑPodcastPlayerLifecycle_Unloaded tuckˑvariantˑunloaded;
        tuckˑtypeˑPodcastPlayerLifecycle_Loading tuckˑvariantˑloading;
        tuckˑtypeˑPodcastPlayerLifecycle_Ready tuckˑvariantˑready;
    }
    bool opEquals(const tuckˑtypeˑPodcastPlayerLifecycle o) const {
        if (kind != o.kind) return false;
        final switch (kind) {
        case tuckˑtypeˑPodcastPlayerLifecycleKind.Unloaded: return tuckˑvariantˑunloaded == o.tuckˑvariantˑunloaded;
        case tuckˑtypeˑPodcastPlayerLifecycleKind.Loading: return tuckˑvariantˑloading == o.tuckˑvariantˑloading;
        case tuckˑtypeˑPodcastPlayerLifecycleKind.Ready: return tuckˑvariantˑready == o.tuckˑvariantˑready;
        }
    }
}

