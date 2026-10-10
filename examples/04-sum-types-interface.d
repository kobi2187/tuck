module _04_sum_types_interface;

import rt = tuck_rt;

struct tuckˑtypeˑConfig {
    string url;
}

struct tuckˑtypeˑFeed {
    string title;
}

struct tuckˑtypeˑAudioPlayer {
    long volume;
}

struct tuckˑtypeˑNetworkClient {
    uint timeout;
}

struct tuckˑtypeˑEpisode {
    string name;
}

struct tuckˑtypeˑPair {
    string key;
    string val;
}

enum tuckˑtypeˑPodcastPlayerLifecycleKind { Unloaded, Loading, Ready, Error }

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
    tuckˑtypeˑAudioPlayer audio;
}

struct tuckˑtypeˑPodcastPlayerLifecycle_Error {
    tuckˑtypeˑConfig config;
    string reason;
}

struct tuckˑtypeˑPodcastPlayerLifecycle {
    tuckˑtypeˑPodcastPlayerLifecycleKind kind;
    union {
        tuckˑtypeˑPodcastPlayerLifecycle_Unloaded tuckˑvariantˑunloaded;
        tuckˑtypeˑPodcastPlayerLifecycle_Loading tuckˑvariantˑloading;
        tuckˑtypeˑPodcastPlayerLifecycle_Ready tuckˑvariantˑready;
        tuckˑtypeˑPodcastPlayerLifecycle_Error tuckˑvariantˑerror;
    }
    bool opEquals(const tuckˑtypeˑPodcastPlayerLifecycle o) const {
        if (kind != o.kind) return false;
        final switch (kind) {
        case tuckˑtypeˑPodcastPlayerLifecycleKind.Unloaded: return tuckˑvariantˑunloaded == o.tuckˑvariantˑunloaded;
        case tuckˑtypeˑPodcastPlayerLifecycleKind.Loading: return tuckˑvariantˑloading == o.tuckˑvariantˑloading;
        case tuckˑtypeˑPodcastPlayerLifecycleKind.Ready: return tuckˑvariantˑready == o.tuckˑvariantˑready;
        case tuckˑtypeˑPodcastPlayerLifecycleKind.Error: return tuckˑvariantˑerror == o.tuckˑvariantˑerror;
        }
    }
    tuckˑtypeˑPodcastPlayerLifecycle tuckCopyOwned() {
        auto outValue = this;
        final switch (kind) {
        case tuckˑtypeˑPodcastPlayerLifecycleKind.Unloaded:
            outValue.tuckˑvariantˑunloaded = rt.tuckCopyG(tuckˑvariantˑunloaded);
            break;
        case tuckˑtypeˑPodcastPlayerLifecycleKind.Loading:
            outValue.tuckˑvariantˑloading = rt.tuckCopyG(tuckˑvariantˑloading);
            break;
        case tuckˑtypeˑPodcastPlayerLifecycleKind.Ready:
            outValue.tuckˑvariantˑready = rt.tuckCopyG(tuckˑvariantˑready);
            break;
        case tuckˑtypeˑPodcastPlayerLifecycleKind.Error:
            outValue.tuckˑvariantˑerror = rt.tuckCopyG(tuckˑvariantˑerror);
            break;
        }
        return outValue;
    }
}

// interface Storable: no satisfying types

tuckˑobjectˑPodcastApp tuckˑfnˑloadEpisode(tuckˑobjectˑPodcastApp self, tuckˑtypeˑEpisode episode) {
    return self;
}

void tuckˑfnˑstartAudio(tuckˑobjectˑPodcastApp self) {
    return;
}

struct tuckˑobjectˑPodcastApp {
    long volume;
    uint timeout;
}

rt.TuckResult!(rt.TuckUnit) tuckˑobjectˑPodcastAppˑsetMany(tuckˑobjectˑPodcastApp self, tuckˑtypeˑPair[] pairs) {
    return typeof(return).init;
}

void tuckˑobjectˑPodcastAppˑplay(ref tuckˑobjectˑPodcastApp self, tuckˑtypeˑEpisode episode) {
    tuckˑobjectˑPodcastApp tuckChain1 = self;
    tuckChain1 = tuckˑfnˑloadEpisode(tuckChain1, episode);
    tuckˑfnˑstartAudio(tuckChain1);
}


