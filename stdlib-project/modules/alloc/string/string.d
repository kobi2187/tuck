module tuck_mod_string;

import rt = tuck_rt;
import str = mod_str;

struct tuck_Builder {
    string[] chunks;
}

tuck_Builder tuck_add(tuck_Builder b, string text) {
    b.chunks = b.chunks.dup;
    return tuck_add_moved(b, text);
}

tuck_Builder tuck_add_moved(tuck_Builder b, string text) {
    string[] tuck_xs = b.chunks;
    tuck_xs ~= text;
    return tuck_Builder(chunks: tuck_xs);
}

string tuck_built(tuck_Builder b) {
    return str.joinStr(b.chunks, "");
}

string tuck_builtWith(tuck_Builder b, string sep) {
    return str.joinStr(b.chunks, sep);
}

long tuck_pieces(tuck_Builder b) {
    return cast(long) b.chunks.length;
}

tuck_Builder tuck_clearBuilder(tuck_Builder b) {
    b.chunks = b.chunks.dup;
    return tuck_clearBuilder_moved(b);
}

tuck_Builder tuck_clearBuilder_moved(tuck_Builder b) {
    string[] tuck_empty = [];
    return tuck_Builder(chunks: tuck_empty);
}

string tuck_append(string t, string other) {
    return (t ~ other);
}

string tuck_clear(string t) {
    return "";
}

string tuck_join(string[] parts, string sep) {
    return str.joinStr(parts, sep);
}

string tuck_slice(string t, long fromByte, long toByte) {
    tuck_Builder tuck_b = (() { auto tuckRecDup1 = tuck_Builder(chunks: []); tuckRecDup1.chunks = tuckRecDup1.chunks.dup; return tuckRecDup1; })();
    foreach (tuck_i; fromByte .. (toByte - 1L) + 1) {
        if (((tuck_i >= 0L) && (tuck_i < cast(long) t.length))) {
            string tuck_ch = str.charAt(t, tuck_i);
            tuck_b = tuck_add_moved(tuck_b, tuck_ch);
        }
    }
    return tuck_built(tuck_b);
}

string tuck_repeat(string t, long times) {
    tuck_Builder tuck_b = (() { auto tuckRecDup2 = tuck_Builder(chunks: []); tuckRecDup2.chunks = tuckRecDup2.chunks.dup; return tuckRecDup2; })();
    foreach (tuck_i; 0L .. (times - 1L) + 1) {
        tuck_b = tuck_add_moved(tuck_b, t);
    }
    return tuck_built(tuck_b);
}

string tuck_insertAt(string t, long index, string other) {
    string tuck_head = tuck_slice(t, 0L, index);
    string tuck_tail = tuck_slice(t, index, cast(long) t.length);
    return ((tuck_head ~ other) ~ tuck_tail);
}

string tuck_removeRange(string t, long fromByte, long toByte) {
    string tuck_head = tuck_slice(t, 0L, fromByte);
    string tuck_tail = tuck_slice(t, toByte, cast(long) t.length);
    return (tuck_head ~ tuck_tail);
}

string tuck_padLeft(string t, long width, string fill) {
    tuck_Builder tuck_b = (() { auto tuckRecDup3 = tuck_Builder(chunks: []); tuckRecDup3.chunks = tuckRecDup3.chunks.dup; return tuckRecDup3; })();
    foreach (tuck_i; 0L .. ((width - cast(long) t.length) - 1L) + 1) {
        tuck_b = tuck_add_moved(tuck_b, fill);
    }
    tuck_b = tuck_add_moved(tuck_b, t);
    return tuck_built(tuck_b);
}

string tuck_padRight(string t, long width, string fill) {
    tuck_Builder tuck_b = (() { auto tuckRecDup4 = tuck_Builder(chunks: []); tuckRecDup4.chunks = tuckRecDup4.chunks.dup; return tuckRecDup4; })();
    tuck_b = tuck_add_moved(tuck_b, t);
    foreach (tuck_i; 0L .. ((width - cast(long) t.length) - 1L) + 1) {
        tuck_b = tuck_add_moved(tuck_b, fill);
    }
    return tuck_built(tuck_b);
}

bool tuck_matchesAt(string t, long at, string what) {
    if (((at + cast(long) what.length) > cast(long) t.length)) {
        return false;
    }
    foreach (tuck_i; 0L .. (cast(long) what.length - 1L) + 1) {
        if ((str.charAt(t, (at + tuck_i)) != str.charAt(what, tuck_i))) {
            return false;
        }
    }
    return true;
}

rt.TuckResult!(long) tuck_indexOf(string t, string what) {
    if ((cast(long) what.length == 0L)) {
        return rt.tok(0L);
    }
    foreach (tuck_i; 0L .. (cast(long) t.length - cast(long) what.length) + 1) {
        if (tuck_matchesAt(t, tuck_i, what)) {
            return rt.tok(tuck_i);
        }
    }
    return rt.tnone!(long)();
}

bool tuck_contains(string t, string what) {
    rt.TuckResult!(long) tuckfn_at = tuck_indexOf(t, what);
    return (tuckfn_at.status == rt.TuckStatus.Ok);
}

string tuck_replace(string t, string what, string into) {
    if ((cast(long) what.length == 0L)) {
        return t;
    }
    tuck_Builder tuck_b = (() { auto tuckRecDup5 = tuck_Builder(chunks: []); tuckRecDup5.chunks = tuckRecDup5.chunks.dup; return tuckRecDup5; })();
    long tuck_i = 0L;
    while ((tuck_i < cast(long) t.length)) {
        if (tuck_matchesAt(t, tuck_i, what)) {
            tuck_b = tuck_add_moved(tuck_b, into);
            tuck_i = (tuck_i + cast(long) what.length);
        } else {
            string tuck_ch = str.charAt(t, tuck_i);
            tuck_b = tuck_add_moved(tuck_b, tuck_ch);
            tuck_i = (tuck_i + 1L);
        }
    }
    return tuck_built(tuck_b);
}

long tuck_checkBuilder() {
    tuck_Builder tuck_b = (() { auto tuckRecDup6 = tuck_Builder(chunks: []); tuckRecDup6.chunks = tuckRecDup6.chunks.dup; return tuckRecDup6; })();
    tuck_b = tuck_add_moved(tuck_b, "a");
    tuck_b = tuck_add_moved(tuck_b, "b");
    tuck_b = tuck_add_moved(tuck_b, "c");
    if ((tuck_pieces(tuck_b) != 3L)) {
        return 1L;
    }
    if ((tuck_built(tuck_b) != "abc")) {
        return 2L;
    }
    if ((tuck_builtWith(tuck_b, "-") != "a-b-c")) {
        return 3L;
    }
    tuck_Builder tuck_empty = (() { auto tuckRecDup7 = tuck_clearBuilder(tuck_b); tuckRecDup7.chunks = tuckRecDup7.chunks.dup; return tuckRecDup7; })();
    if ((tuck_pieces(tuck_empty) != 0L)) {
        return 4L;
    }
    if ((tuck_built(tuck_empty) != "")) {
        return 5L;
    }
    return tuck_checkSlice();
}

long tuck_checkSlice() {
    if ((tuck_slice("hello", 1L, 3L) != "el")) {
        return 6L;
    }
    if ((tuck_slice("hi", 0L, 99L) != "hi")) {
        return 7L;
    }
    if ((tuck_repeat("ab", 3L) != "ababab")) {
        return 8L;
    }
    if ((tuck_insertAt("hello", 2L, "XY") != "heXYllo")) {
        return 9L;
    }
    if ((tuck_removeRange("hello", 1L, 3L) != "hlo")) {
        return 10L;
    }
    return tuck_checkPadAndReplace();
}

long tuck_checkPadAndReplace() {
    if ((tuck_padLeft("7", 3L, "0") != "007")) {
        return 11L;
    }
    if ((tuck_padRight("7", 3L, ".") != "7..")) {
        return 12L;
    }
    if ((tuck_padLeft("abcd", 2L, "0") != "abcd")) {
        return 13L;
    }
    if ((tuck_replace("a,b,c", ",", ";") != "a;b;c")) {
        return 14L;
    }
    if ((tuck_replace("aaa", "aa", "b") != "ba")) {
        return 15L;
    }
    string[] tuck_parts = ["x", "y"];
    if ((tuck_join(tuck_parts, "+") != "x+y")) {
        return 16L;
    }
    return tuck_checkSearch();
}

long tuck_checkSearch() {
    rt.TuckResult!(long) tuckfn_at = tuck_indexOf("hello", "ll");
    if (!(tuckfn_at.status == rt.TuckStatus.Ok)) {
        return 17L;
    }
    if ((tuckfn_at.value != 2L)) {
        return 18L;
    }
    rt.TuckResult!(long) tuck_missing = tuck_indexOf("hello", "zz");
    if ((tuck_missing.status == rt.TuckStatus.Ok)) {
        return 19L;
    }
    if (!tuck_contains("hello", "hell")) {
        return 20L;
    }
    if ((tuck_append("abc", "d") != "abcd")) {
        return 21L;
    }
    if ((tuck_clear("abc") != "")) {
        return 22L;
    }
    return 0L;
}

long tuck_main() {
    return tuck_checkBuilder();
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_main();
    return cast(int) mainRc;
}
