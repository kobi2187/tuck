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
        tuck_PodcastPlayerLifecycle_Unloaded unloaded;
        tuck_PodcastPlayerLifecycle_Loading loading;
        tuck_PodcastPlayerLifecycle_Ready ready;
    }
}

