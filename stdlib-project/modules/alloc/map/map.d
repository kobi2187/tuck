module map;

import rt = tuck_rt;

struct tuck_Entry(K, V) {
    K key;
    V value;
}

struct tuck_Table(K, V) {
    tuck_Entry!(K, V)[] entries;
}

long tuck_indexOf(K, V)(tuck_Table!(K, V) t, K key) {
    foreach (tuck_i; 0L .. (cast(long) t.entries.length - 1L) + 1) {
        tuck_Entry!(K, V) tuck_e = rt.tuckAt(t.entries, tuck_i);
        if ((tuck_e.key == key)) {
            return tuck_i;
        }
    }
    return (0L - 1L);
}

bool tuck_has(K, V)(tuck_Table!(K, V) t, K key) {
    return (tuck_indexOf(t, key) >= 0L);
}

long tuck_count(K, V)(tuck_Table!(K, V) t) {
    return cast(long) t.entries.length;
}

rt.TuckResult!(V) tuck_get(K, V)(tuck_Table!(K, V) t, K key) {
    long tuckfn_at = tuck_indexOf(t, key);
    if ((tuckfn_at < 0L)) {
        return rt.tnone!(V)();
    }
    return rt.tok(rt.tuckAt(t.entries, tuckfn_at).value);
}

tuck_Table!(K, V) tuck_set(K, V)(tuck_Table!(K, V) t, K key, V value) {
    t.entries = t.entries.dup;
    return tuck_set_moved(t, key, value);
}

tuck_Table!(K, V) tuck_set_moved(K, V)(tuck_Table!(K, V) t, K key, V value) {
    long tuckfn_at = tuck_indexOf(t, key);
    tuck_Entry!(K, V)[] tuck_es = t.entries;
    tuck_Entry!(K, V) tuck_fresh = tuck_Entry!(K, V)(key: key, value: value);
    if ((tuckfn_at >= 0L)) {
        rt.tuckSetAt(tuck_es, tuckfn_at, tuck_fresh);
        return tuck_Table!(K, V)(entries: tuck_es);
    }
    tuck_es ~= tuck_fresh;
    return tuck_Table!(K, V)(entries: tuck_es);
}

tuck_Table!(K, V) tuck_getOrSet(K, V)(tuck_Table!(K, V) t, K key, V value) {
    t.entries = t.entries.dup;
    return tuck_getOrSet_moved(t, key, value);
}

tuck_Table!(K, V) tuck_getOrSet_moved(K, V)(tuck_Table!(K, V) t, K key, V value) {
    if (tuck_has(t, key)) {
        return t;
    }
    return tuck_set(t, key, value);
}

tuck_Table!(K, V) tuck_remove(K, V)(tuck_Table!(K, V) t, K key) {
    t.entries = t.entries.dup;
    return tuck_remove_moved(t, key);
}

tuck_Table!(K, V) tuck_remove_moved(K, V)(tuck_Table!(K, V) t, K key) {
    tuck_Entry!(K, V)[] tuck_es = [];
    foreach (tuck_i; 0L .. (cast(long) t.entries.length - 1L) + 1) {
        tuck_Entry!(K, V) tuck_e = rt.tuckAt(t.entries, tuck_i);
        if ((tuck_e.key != key)) {
            tuck_es ~= tuck_e;
        }
    }
    return tuck_Table!(K, V)(entries: tuck_es);
}

tuck_Table!(K, V) tuck_clear(K, V)(tuck_Table!(K, V) t) {
    t.entries = t.entries.dup;
    return tuck_clear_moved(t);
}

tuck_Table!(K, V) tuck_clear_moved(K, V)(tuck_Table!(K, V) t) {
    tuck_Entry!(K, V)[] tuck_empty = [];
    return tuck_Table!(K, V)(entries: tuck_empty);
}

K[] tuck_keys(K, V)(tuck_Table!(K, V) t) {
    K[] tuck_acc = [];
    foreach (tuck_i; 0L .. (cast(long) t.entries.length - 1L) + 1) {
        tuck_acc ~= rt.tuckAt(t.entries, tuck_i).key;
    }
    return tuck_acc;
}

V[] tuck_values(K, V)(tuck_Table!(K, V) t) {
    V[] tuck_acc = [];
    foreach (tuck_i; 0L .. (cast(long) t.entries.length - 1L) + 1) {
        tuck_acc ~= rt.tuckAt(t.entries, tuck_i).value;
    }
    return tuck_acc;
}

tuck_Entry!(K, V)[] tuck_pairs(K, V)(tuck_Table!(K, V) t) {
    return t.entries;
}

long tuck_main() {
    tuck_Table!(string, long) tuck_rooms = tuck_Table!(string, long)(entries: []);
    tuck_rooms = tuck_set_moved(tuck_rooms, "lobby", 1L);
    tuck_rooms = tuck_set_moved(tuck_rooms, "attic", 2L);
    if ((tuck_count(tuck_rooms) != 2L)) {
        return 1L;
    }
    rt.TuckResult!(long) tuck_lobby = tuck_get(tuck_rooms, "lobby");
    if (!(tuck_lobby.status == rt.TuckStatus.Ok)) {
        return 2L;
    }
    if ((tuck_lobby.value != 1L)) {
        return 3L;
    }
    rt.TuckResult!(long) tuck_missing = tuck_get(tuck_rooms, "cellar");
    if ((tuck_missing.status == rt.TuckStatus.Ok)) {
        return 4L;
    }
    tuck_rooms = tuck_set_moved(tuck_rooms, "lobby", 9L);
    if ((tuck_count(tuck_rooms) != 2L)) {
        return 5L;
    }
    rt.TuckResult!(long) tuck_again = tuck_get(tuck_rooms, "lobby");
    if (!(tuck_again.status == rt.TuckStatus.Ok)) {
        return 6L;
    }
    if ((tuck_again.value != 9L)) {
        return 14L;
    }
    tuck_rooms = tuck_getOrSet_moved(tuck_rooms, "lobby", 99L);
    rt.TuckResult!(long) tuck_kept = tuck_get(tuck_rooms, "lobby");
    if (!(tuck_kept.status == rt.TuckStatus.Ok)) {
        return 7L;
    }
    if ((tuck_kept.value != 9L)) {
        return 15L;
    }
    if (!tuck_has(tuck_rooms, "attic")) {
        return 8L;
    }
    tuck_rooms = tuck_remove_moved(tuck_rooms, "attic");
    if (tuck_has(tuck_rooms, "attic")) {
        return 9L;
    }
    if ((tuck_count(tuck_rooms) != 1L)) {
        return 10L;
    }
    string[] tuck_ks = (tuck_keys(tuck_rooms)).dup;
    if ((cast(long) tuck_ks.length != 1L)) {
        return 11L;
    }
    long[] tuck_vs = (tuck_values(tuck_rooms)).dup;
    if ((cast(long) tuck_vs.length != 1L)) {
        return 12L;
    }
    tuck_rooms = tuck_clear_moved(tuck_rooms);
    if ((tuck_count(tuck_rooms) != 0L)) {
        return 13L;
    }
    return 0L;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_main();
    return cast(int) mainRc;
}
