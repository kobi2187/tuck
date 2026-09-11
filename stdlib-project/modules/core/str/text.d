module text;

import rt = tuck_rt;
import str = mod_str;
import seq = mod_seq;

alias tuck_Rune = uint;

alias tuck_Char = ubyte;

bool tuck_isEmpty(string t) {
    return (str.byteCount(t) == 0L);
}

rt.TuckResult!(tuck_Char) tuck_charAtByte(string t, long index) {
    if (((index < 0L) || (index >= str.byteCount(t)))) {
        return rt.tnone!(tuck_Char)();
    }
    return rt.tok(str.byteAt(t, index));
}

long tuck_runeWidth(ubyte lead) {
    long tuck_b = cast(long)(lead);
    if ((tuck_b < 128L)) {
        return 1L;
    }
    if ((tuck_b < 224L)) {
        return 2L;
    }
    if ((tuck_b < 240L)) {
        return 3L;
    }
    return 4L;
}

long tuck_continuationBits(string t, long index) {
    if ((index >= str.byteCount(t))) {
        return 0L;
    }
    ubyte tuck_b = str.byteAt(t, index);
    return (cast(long)(tuck_b) % 64L);
}

long tuck_leadBits(ubyte lead, long width) {
    long tuck_b = cast(long)(lead);
    if ((width == 1L)) {
        return tuck_b;
    }
    if ((width == 2L)) {
        return (tuck_b % 32L);
    }
    if ((width == 3L)) {
        return (tuck_b % 16L);
    }
    return (tuck_b % 8L);
}

rt.TuckResult!(tuck_Rune) tuck_runeAt(string t, long at) {
    if (((at < 0L) || (at >= str.byteCount(t)))) {
        return rt.tnone!(tuck_Rune)();
    }
    ubyte tuck_lead = str.byteAt(t, at);
    long tuck_width = tuck_runeWidth(tuck_lead);
    long tuck_acc = tuck_leadBits(tuck_lead, tuck_width);
    foreach (tuck_i; 1L .. (tuck_width - 1L) + 1) {
        tuck_acc = ((tuck_acc * 64L) + tuck_continuationBits(t, (at + tuck_i)));
    }
    return rt.tok(cast(uint)(tuck_acc));
}

long tuck_nextRune(string t, long at) {
    ubyte tuck_lead = str.byteAt(t, at);
    return (at + tuck_runeWidth(tuck_lead));
}

long tuck_runeCount(string t) {
    long tuck_n = 0L;
    long tuckfn_at = 0L;
    while ((tuckfn_at < str.byteCount(t))) {
        tuck_n = (tuck_n + 1L);
        tuckfn_at = tuck_nextRune(t, tuckfn_at);
    }
    return tuck_n;
}

tuck_Rune[] tuck_noRunes() {
    return [];
}

tuck_Rune[] tuck_runes(string t) {
    tuck_Rune[] tuck_acc = (tuck_noRunes()).dup;
    long tuckfn_at = 0L;
    while ((tuckfn_at < str.byteCount(t))) {
        rt.TuckResult!(tuck_Rune) tuck_r = tuck_runeAt(t, tuckfn_at);
        if ((tuck_r.status == rt.TuckStatus.Ok)) {
            tuck_acc ~= tuck_r.value;
        }
        tuckfn_at = tuck_nextRune(t, tuckfn_at);
    }
    return tuck_acc;
}

ubyte[] tuck_noBytes() {
    return [];
}

ubyte[] tuck_encodeRune(tuck_Rune r, ubyte[] into) {
    long tuck_v = cast(long)(r);
    ubyte[] tuck_out = (into).dup;
    if ((tuck_v < 128L)) {
        ubyte tuck_b = cast(ubyte)(tuck_v);
        return seq.push(tuck_out, tuck_b);
    }
    if ((tuck_v < 2048L)) {
        ubyte tuck_lead = cast(ubyte)((192L + (tuck_v / 64L)));
        tuck_out ~= tuck_lead;
        ubyte tuck_tail = cast(ubyte)((128L + (tuck_v % 64L)));
        return seq.push(tuck_out, tuck_tail);
    }
    if ((tuck_v < 65536L)) {
        ubyte tuck_lead = cast(ubyte)((224L + (tuck_v / 4096L)));
        tuck_out ~= tuck_lead;
        ubyte tuck_mid = cast(ubyte)((128L + ((tuck_v / 64L) % 64L)));
        tuck_out ~= tuck_mid;
        ubyte tuck_tail = cast(ubyte)((128L + (tuck_v % 64L)));
        return seq.push(tuck_out, tuck_tail);
    }
    ubyte tuck_lead = cast(ubyte)((240L + (tuck_v / 262144L)));
    tuck_out ~= tuck_lead;
    ubyte tuck_hi = cast(ubyte)((128L + ((tuck_v / 4096L) % 64L)));
    tuck_out ~= tuck_hi;
    ubyte tuck_mid = cast(ubyte)((128L + ((tuck_v / 64L) % 64L)));
    tuck_out ~= tuck_mid;
    ubyte tuck_tail = cast(ubyte)((128L + (tuck_v % 64L)));
    return seq.push(tuck_out, tuck_tail);
}

string tuck_fromRunes(tuck_Rune[] rs) {
    ubyte[] tuck_bytes = (tuck_noBytes()).dup;
    foreach (tuck_i; 0L .. (seq.count(rs) - 1L) + 1) {
        tuck_bytes = (tuck_encodeRune(rt.tuckAt(rs, tuck_i), tuck_bytes)).dup;
    }
    return str.fromBytes(tuck_bytes);
}

bool tuck_matchesAt(string t, long at, string what) {
    long tuck_n = str.byteCount(what);
    if (((at + tuck_n) > str.byteCount(t))) {
        return false;
    }
    foreach (tuck_i; 0L .. (tuck_n - 1L) + 1) {
        if ((str.byteAt(t, (at + tuck_i)) != str.byteAt(what, tuck_i))) {
            return false;
        }
    }
    return true;
}

rt.TuckResult!(long) tuck_find(string t, string what) {
    if ((str.byteCount(what) == 0L)) {
        return rt.tok(0L);
    }
    foreach (tuck_i; 0L .. (str.byteCount(t) - str.byteCount(what)) + 1) {
        if (tuck_matchesAt(t, tuck_i, what)) {
            return rt.tok(tuck_i);
        }
    }
    return rt.tnone!(long)();
}

bool tuck_has(string t, string what) {
    rt.TuckResult!(long) tuckfn_at = tuck_find(t, what);
    return (tuckfn_at.status == rt.TuckStatus.Ok);
}

bool tuck_startsWith(string t, string prefix) {
    return tuck_matchesAt(t, 0L, prefix);
}

bool tuck_endsWith(string t, string suffix) {
    long tuckfn_at = (str.byteCount(t) - str.byteCount(suffix));
    if ((tuckfn_at < 0L)) {
        return false;
    }
    return tuck_matchesAt(t, tuckfn_at, suffix);
}

rt.TuckResult!(string) tuck_slice(string t, long start, long stop) {
    if (((start < 0L) || ((stop > str.byteCount(t)) || (start > stop)))) {
        return rt.tnone!(string)();
    }
    ubyte[] tuck_out = (tuck_noBytes()).dup;
    foreach (tuck_i; start .. (stop - 1L) + 1) {
        ubyte tuck_b = str.byteAt(t, tuck_i);
        tuck_out ~= tuck_b;
    }
    return rt.tok(str.fromBytes(tuck_out));
}

string[] tuck_noParts() {
    return [];
}

string[] tuck_split(string t, string at) {
    string[] tuck_parts = (tuck_noParts()).dup;
    if ((str.byteCount(at) == 0L)) {
        return seq.push(tuck_parts, t);
    }
    long tuck_start = 0L;
    long tuck_i = 0L;
    while ((tuck_i <= (str.byteCount(t) - str.byteCount(at)))) {
        if (tuck_matchesAt(t, tuck_i, at)) {
            rt.TuckResult!(string) tuck_piece = tuck_slice(t, tuck_start, tuck_i);
            if ((tuck_piece.status == rt.TuckStatus.Ok)) {
                tuck_parts ~= tuck_piece.value;
            }
            tuck_i = (tuck_i + str.byteCount(at));
            tuck_start = tuck_i;
        } else {
            tuck_i = (tuck_i + 1L);
        }
    }
    long tuck_n = str.byteCount(t);
    rt.TuckResult!(string) tuck_last = tuck_slice(t, tuck_start, tuck_n);
    if ((tuck_last.status == rt.TuckStatus.Ok)) {
        tuck_parts ~= tuck_last.value;
    }
    return tuck_parts;
}

bool tuck_isSpaceByte(ubyte b) {
    long tuck_v = cast(long)(b);
    return ((tuck_v == 32L) || ((tuck_v == 9L) || ((tuck_v == 10L) || (tuck_v == 13L))));
}

string tuck_trimStart(string t) {
    long tuck_i = 0L;
    while ((tuck_i < str.byteCount(t))) {
        ubyte tuck_b = str.byteAt(t, tuck_i);
        if (!tuck_isSpaceByte(tuck_b)) {
            break;
        }
        tuck_i = (tuck_i + 1L);
    }
    long tuck_n = str.byteCount(t);
    rt.TuckResult!(string) tuck_out = tuck_slice(t, tuck_i, tuck_n);
    if (!(tuck_out.status == rt.TuckStatus.Ok)) {
        return "";
    }
    return tuck_out.value;
}

string tuck_trimEnd(string t) {
    long tuck_n = str.byteCount(t);
    while ((tuck_n > 0L)) {
        ubyte tuck_b = str.byteAt(t, (tuck_n - 1L));
        if (!tuck_isSpaceByte(tuck_b)) {
            break;
        }
        tuck_n = (tuck_n - 1L);
    }
    rt.TuckResult!(string) tuck_out = tuck_slice(t, 0L, tuck_n);
    if (!(tuck_out.status == rt.TuckStatus.Ok)) {
        return "";
    }
    return tuck_out.value;
}

string tuck_trim(string t) {
    string tuck_head = tuck_trimStart(t);
    return tuck_trimEnd(tuck_head);
}

ubyte tuck_lowerByte(ubyte b) {
    long tuck_v = cast(long)(b);
    if (((tuck_v >= 65L) && (tuck_v <= 90L))) {
        return cast(ubyte)((tuck_v + 32L));
    }
    return b;
}

ubyte tuck_upperByte(ubyte b) {
    long tuck_v = cast(long)(b);
    if (((tuck_v >= 97L) && (tuck_v <= 122L))) {
        return cast(ubyte)((tuck_v - 32L));
    }
    return b;
}

string tuck_toLowerAscii(string t) {
    ubyte[] tuck_out = (tuck_noBytes()).dup;
    foreach (tuck_i; 0L .. (str.byteCount(t) - 1L) + 1) {
        ubyte tuck_b = str.byteAt(t, tuck_i);
        ubyte tuck_low = tuck_lowerByte(tuck_b);
        tuck_out ~= tuck_low;
    }
    return str.fromBytes(tuck_out);
}

string tuck_toUpperAscii(string t) {
    ubyte[] tuck_out = (tuck_noBytes()).dup;
    foreach (tuck_i; 0L .. (str.byteCount(t) - 1L) + 1) {
        ubyte tuck_b = str.byteAt(t, tuck_i);
        ubyte tuck_up = tuck_upperByte(tuck_b);
        tuck_out ~= tuck_up;
    }
    return str.fromBytes(tuck_out);
}

long tuck_checkAscii() {
    if (!tuck_isEmpty("")) {
        return 1L;
    }
    if (tuck_isEmpty("a")) {
        return 2L;
    }
    rt.TuckResult!(tuck_Char) tuck_c = tuck_charAtByte("abc", 1L);
    if (!(tuck_c.status == rt.TuckStatus.Ok)) {
        return 3L;
    }
    if ((cast(long)(tuck_c.value) != 98L)) {
        return 4L;
    }
    rt.TuckResult!(tuck_Char) tuck_past = tuck_charAtByte("abc", 9L);
    if ((tuck_past.status == rt.TuckStatus.Ok)) {
        return 5L;
    }
    return tuck_checkSearch();
}

long tuck_checkSearch() {
    rt.TuckResult!(long) tuckfn_at = tuck_find("hello", "ll");
    if (!(tuckfn_at.status == rt.TuckStatus.Ok)) {
        return 6L;
    }
    if ((tuckfn_at.value != 2L)) {
        return 7L;
    }
    rt.TuckResult!(long) tuck_missing = tuck_find("hello", "zz");
    if ((tuck_missing.status == rt.TuckStatus.Ok)) {
        return 8L;
    }
    if (!tuck_has("hello", "ell")) {
        return 9L;
    }
    if (!tuck_startsWith("hello", "he")) {
        return 10L;
    }
    if (!tuck_endsWith("hello", "lo")) {
        return 11L;
    }
    if (tuck_endsWith("hi", "longer")) {
        return 12L;
    }
    return tuck_checkSliceSplit();
}

long tuck_checkSliceSplit() {
    rt.TuckResult!(string) tuck_s = tuck_slice("hello", 1L, 3L);
    if (!(tuck_s.status == rt.TuckStatus.Ok)) {
        return 13L;
    }
    if ((tuck_s.value != "el")) {
        return 14L;
    }
    rt.TuckResult!(string) tuck_bad = tuck_slice("hi", 0L, 99L);
    if ((tuck_bad.status == rt.TuckStatus.Ok)) {
        return 15L;
    }
    string[] tuck_parts = (tuck_split("a,b,c", ",")).dup;
    if ((seq.count(tuck_parts) != 3L)) {
        return 16L;
    }
    if ((rt.tuckAt(tuck_parts, 0L) != "a")) {
        return 17L;
    }
    if ((rt.tuckAt(tuck_parts, 2L) != "c")) {
        return 18L;
    }
    return tuck_checkTrimCase();
}

long tuck_checkTrimCase() {
    if ((tuck_trim("  hi  ") != "hi")) {
        return 19L;
    }
    if ((tuck_trimStart("  hi") != "hi")) {
        return 20L;
    }
    if ((tuck_trimEnd("hi  ") != "hi")) {
        return 21L;
    }
    if ((tuck_trim("   ") != "")) {
        return 22L;
    }
    if ((tuck_toLowerAscii("AbC") != "abc")) {
        return 23L;
    }
    if ((tuck_toUpperAscii("AbC") != "ABC")) {
        return 24L;
    }
    return tuck_checkRunes();
}

long tuck_checkRunes() {
    string tuck_s = "héllo";
    if ((str.byteCount(tuck_s) != 6L)) {
        return 25L;
    }
    if ((tuck_runeCount(tuck_s) != 5L)) {
        return 26L;
    }
    rt.TuckResult!(tuck_Rune) tuck_r = tuck_runeAt(tuck_s, 1L);
    if (!(tuck_r.status == rt.TuckStatus.Ok)) {
        return 27L;
    }
    if ((cast(long)(tuck_r.value) != 233L)) {
        return 28L;
    }
    tuck_Rune[] tuck_rs = (tuck_runes(tuck_s)).dup;
    if ((seq.count(tuck_rs) != 5L)) {
        return 29L;
    }
    tuck_Rune[] tuck_rs2 = (tuck_runes(tuck_s)).dup;
    if ((tuck_fromRunes(tuck_rs2) != tuck_s)) {
        return 30L;
    }
    return 0L;
}

long tuck_main() {
    return tuck_checkAscii();
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_main();
    return cast(int) mainRc;
}
