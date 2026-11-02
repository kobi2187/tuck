module mod_text;

import rt = tuck_rt;
import tuckˑmodˑseq = mod_seq;
import tuckˑmodˑstr = mod_str;

alias tuckˑtypeˑRune = uint;

alias tuckˑtypeˑChar = ubyte;

bool tuckˑfnˑisEmpty(string t) {
    return (tuckˑmodˑstr.byteCount(t) == 0L);
}

rt.TuckResult!(tuckˑtypeˑChar) tuckˑfnˑcharAtByte(string t, long index) {
    if (((index < 0L) || (index >= tuckˑmodˑstr.byteCount(t)))) {
        return rt.tnone!(tuckˑtypeˑChar)();
    }
    return rt.tok(tuckˑmodˑstr.byteAt(t, index));
}

long tuckˑfnˑruneWidth(ubyte lead) {
    long tuckˑvˑb = cast(long)(lead);
    if ((tuckˑvˑb < 128L)) {
        return 1L;
    }
    if ((tuckˑvˑb < 224L)) {
        return 2L;
    }
    if ((tuckˑvˑb < 240L)) {
        return 3L;
    }
    return 4L;
}

long tuckˑfnˑcontinuationBits(string t, long index) {
    if ((index >= tuckˑmodˑstr.byteCount(t))) {
        return 0L;
    }
    ubyte tuckˑvˑb = tuckˑmodˑstr.byteAt(t, index);
    return (cast(long)(tuckˑvˑb) % 64L);
}

long tuckˑfnˑleadBits(ubyte lead, long width) {
    long tuckˑvˑb = cast(long)(lead);
    if ((width == 1L)) {
        return tuckˑvˑb;
    }
    if ((width == 2L)) {
        return (tuckˑvˑb % 32L);
    }
    if ((width == 3L)) {
        return (tuckˑvˑb % 16L);
    }
    return (tuckˑvˑb % 8L);
}

rt.TuckResult!(tuckˑtypeˑRune) tuckˑfnˑruneAt(string t, long at) {
    if (((at < 0L) || (at >= tuckˑmodˑstr.byteCount(t)))) {
        return rt.tnone!(tuckˑtypeˑRune)();
    }
    ubyte tuckˑvˑlead = tuckˑmodˑstr.byteAt(t, at);
    long tuckˑvˑwidth = tuckˑfnˑruneWidth(tuckˑvˑlead);
    long tuckˑvˑacc = tuckˑfnˑleadBits(tuckˑvˑlead, tuckˑvˑwidth);
    foreach (tuckˑvˑi; 1L .. (tuckˑvˑwidth - 1L) + 1) {
        tuckˑvˑacc = ((tuckˑvˑacc * 64L) + tuckˑfnˑcontinuationBits(t, (at + tuckˑvˑi)));
    }
    return rt.tok(cast(uint)(tuckˑvˑacc));
}

long tuckˑfnˑnextRune(string t, long at) {
    ubyte tuckˑvˑlead = tuckˑmodˑstr.byteAt(t, at);
    return (at + tuckˑfnˑruneWidth(tuckˑvˑlead));
}

long tuckˑfnˑruneCount(string t) {
    long tuckˑvˑn = 0L;
    long tuckˑvˑat = 0L;
    while ((tuckˑvˑat < tuckˑmodˑstr.byteCount(t))) {
        tuckˑvˑn = (tuckˑvˑn + 1L);
        tuckˑvˑat = tuckˑfnˑnextRune(t, tuckˑvˑat);
    }
    return tuckˑvˑn;
}

tuckˑtypeˑRune[] tuckˑfnˑnoRunes() {
    return [];
}

tuckˑtypeˑRune[] tuckˑfnˑrunes(string t) {
    tuckˑtypeˑRune[] tuckˑvˑacc = tuckˑfnˑnoRunes();
    long tuckˑvˑat = 0L;
    while ((tuckˑvˑat < tuckˑmodˑstr.byteCount(t))) {
        rt.TuckResult!(tuckˑtypeˑRune) tuckˑvˑr = tuckˑfnˑruneAt(t, tuckˑvˑat);
        if ((tuckˑvˑr.status == rt.TuckStatus.Ok)) {
            rt.tuckPush(tuckˑvˑacc, tuckˑvˑr.value);
        }
        tuckˑvˑat = tuckˑfnˑnextRune(t, tuckˑvˑat);
    }
    return tuckˑvˑacc;
}

ubyte[] tuckˑfnˑnoBytes() {
    return [];
}

ubyte[] tuckˑfnˑencodeRune(tuckˑtypeˑRune r, ubyte[] into) {
    long tuckˑvˑv = cast(long)(r);
    ubyte[] tuckˑvˑout = into;
    scope(exit) rt.tuckDrop(tuckˑvˑout);
    if ((tuckˑvˑv < 128L)) {
        ubyte tuckˑvˑb = cast(ubyte)(tuckˑvˑv);
        return tuckˑmodˑseq.push(tuckˑvˑout, tuckˑvˑb);
    }
    if ((tuckˑvˑv < 2048L)) {
        ubyte tuckˑvˑlead = cast(ubyte)((192L + (tuckˑvˑv / 64L)));
        rt.tuckPush(tuckˑvˑout, tuckˑvˑlead);
        ubyte tuckˑvˑtail = cast(ubyte)((128L + (tuckˑvˑv % 64L)));
        return tuckˑmodˑseq.push(tuckˑvˑout, tuckˑvˑtail);
    }
    if ((tuckˑvˑv < 65536L)) {
        ubyte tuckˑvˑleadˑ1 = cast(ubyte)((224L + (tuckˑvˑv / 4096L)));
        rt.tuckPush(tuckˑvˑout, tuckˑvˑleadˑ1);
        ubyte tuckˑvˑmid = cast(ubyte)((128L + ((tuckˑvˑv / 64L) % 64L)));
        rt.tuckPush(tuckˑvˑout, tuckˑvˑmid);
        ubyte tuckˑvˑtailˑ2 = cast(ubyte)((128L + (tuckˑvˑv % 64L)));
        return tuckˑmodˑseq.push(tuckˑvˑout, tuckˑvˑtailˑ2);
    }
    ubyte tuckˑvˑleadˑ3 = cast(ubyte)((240L + (tuckˑvˑv / 262144L)));
    rt.tuckPush(tuckˑvˑout, tuckˑvˑleadˑ3);
    ubyte tuckˑvˑhi = cast(ubyte)((128L + ((tuckˑvˑv / 4096L) % 64L)));
    rt.tuckPush(tuckˑvˑout, tuckˑvˑhi);
    ubyte tuckˑvˑmidˑ4 = cast(ubyte)((128L + ((tuckˑvˑv / 64L) % 64L)));
    rt.tuckPush(tuckˑvˑout, tuckˑvˑmidˑ4);
    ubyte tuckˑvˑtailˑ5 = cast(ubyte)((128L + (tuckˑvˑv % 64L)));
    return tuckˑmodˑseq.push(tuckˑvˑout, tuckˑvˑtailˑ5);
}

string tuckˑfnˑfromRunes(tuckˑtypeˑRune[] rs) {
    ubyte[] tuckˑvˑbytes = tuckˑfnˑnoBytes();
    scope(exit) rt.tuckDrop(tuckˑvˑbytes);
    foreach (tuckˑvˑi; 0L .. (tuckˑmodˑseq.count(rs) - 1L) + 1) {
        tuckˑvˑbytes = tuckˑfnˑencodeRune(rt.tuckAt(rs, tuckˑvˑi), tuckˑvˑbytes);
    }
    return tuckˑmodˑstr.fromBytes(tuckˑvˑbytes);
}

bool tuckˑfnˑmatchesAt(string t, long at, string what) {
    long tuckˑvˑn = tuckˑmodˑstr.byteCount(what);
    if (((at + tuckˑvˑn) > tuckˑmodˑstr.byteCount(t))) {
        return false;
    }
    foreach (tuckˑvˑi; 0L .. (tuckˑvˑn - 1L) + 1) {
        if ((tuckˑmodˑstr.byteAt(t, (at + tuckˑvˑi)) != tuckˑmodˑstr.byteAt(what, tuckˑvˑi))) {
            return false;
        }
    }
    return true;
}

rt.TuckResult!(long) tuckˑfnˑfind(string t, string what) {
    if ((tuckˑmodˑstr.byteCount(what) == 0L)) {
        return rt.tok(0L);
    }
    foreach (tuckˑvˑi; 0L .. (tuckˑmodˑstr.byteCount(t) - tuckˑmodˑstr.byteCount(what)) + 1) {
        if (tuckˑfnˑmatchesAt(t, tuckˑvˑi, what)) {
            return rt.tok(tuckˑvˑi);
        }
    }
    return rt.tnone!(long)();
}

bool tuckˑfnˑhas(string t, string what) {
    rt.TuckResult!(long) tuckˑvˑat = tuckˑfnˑfind(t, what);
    return (tuckˑvˑat.status == rt.TuckStatus.Ok);
}

bool tuckˑfnˑstartsWith(string t, string prefix) {
    return tuckˑfnˑmatchesAt(t, 0L, prefix);
}

bool tuckˑfnˑendsWith(string t, string suffix) {
    long tuckˑvˑat = (tuckˑmodˑstr.byteCount(t) - tuckˑmodˑstr.byteCount(suffix));
    if ((tuckˑvˑat < 0L)) {
        return false;
    }
    return tuckˑfnˑmatchesAt(t, tuckˑvˑat, suffix);
}

rt.TuckResult!(string) tuckˑfnˑslice(string t, long start, long stop) {
    if (((start < 0L) || ((stop > tuckˑmodˑstr.byteCount(t)) || (start > stop)))) {
        return rt.tnone!(string)();
    }
    ubyte[] tuckˑvˑout = tuckˑfnˑnoBytes();
    scope(exit) rt.tuckDrop(tuckˑvˑout);
    foreach (tuckˑvˑi; start .. (stop - 1L) + 1) {
        ubyte tuckˑvˑb = tuckˑmodˑstr.byteAt(t, tuckˑvˑi);
        rt.tuckPush(tuckˑvˑout, tuckˑvˑb);
    }
    return rt.tok(tuckˑmodˑstr.fromBytes(tuckˑvˑout));
}

string[] tuckˑfnˑnoParts() {
    return [];
}

string[] tuckˑfnˑsplit(string t, string at) {
    scope(exit) rt.tuckDrop(t);
    string[] tuckˑvˑparts = tuckˑfnˑnoParts();
    scope(exit) rt.tuckDrop(tuckˑvˑparts);
    if ((tuckˑmodˑstr.byteCount(at) == 0L)) {
        string[] tuckOwnTmp2 = tuckˑmodˑseq.push(tuckˑvˑparts, t);
        t = typeof(t).init;
        return tuckOwnTmp2;
    }
    long tuckˑvˑstart = 0L;
    long tuckˑvˑi = 0L;
    while ((tuckˑvˑi <= (tuckˑmodˑstr.byteCount(t) - tuckˑmodˑstr.byteCount(at)))) {
        if (tuckˑfnˑmatchesAt(t, tuckˑvˑi, at)) {
            rt.TuckResult!(string) tuckˑvˑpiece = tuckˑfnˑslice(t, tuckˑvˑstart, tuckˑvˑi);
            scope(exit) rt.tuckDrop(tuckˑvˑpiece);
            if ((tuckˑvˑpiece.status == rt.TuckStatus.Ok)) {
                rt.tuckPush(tuckˑvˑparts, tuckˑvˑpiece.value);
                tuckˑvˑpiece.value = typeof(tuckˑvˑpiece.value).init;
            }
            tuckˑvˑi = (tuckˑvˑi + tuckˑmodˑstr.byteCount(at));
            tuckˑvˑstart = tuckˑvˑi;
        } else {
            tuckˑvˑi = (tuckˑvˑi + 1L);
        }
    }
    long tuckˑvˑn = tuckˑmodˑstr.byteCount(t);
    rt.TuckResult!(string) tuckˑvˑlast = tuckˑfnˑslice(t, tuckˑvˑstart, tuckˑvˑn);
    scope(exit) rt.tuckDrop(tuckˑvˑlast);
    if ((tuckˑvˑlast.status == rt.TuckStatus.Ok)) {
        rt.tuckPush(tuckˑvˑparts, tuckˑvˑlast.value);
        tuckˑvˑlast.value = typeof(tuckˑvˑlast.value).init;
    }
    string[] tuckOwnTmp1 = tuckˑvˑparts;
    tuckˑvˑparts = typeof(tuckˑvˑparts).init;
    return tuckOwnTmp1;
}

bool tuckˑfnˑisSpaceByte(ubyte b) {
    long tuckˑvˑv = cast(long)(b);
    return ((tuckˑvˑv == 32L) || ((tuckˑvˑv == 9L) || ((tuckˑvˑv == 10L) || (tuckˑvˑv == 13L))));
}

string tuckˑfnˑtrimStart(string t) {
    long tuckˑvˑi = 0L;
    while ((tuckˑvˑi < tuckˑmodˑstr.byteCount(t))) {
        ubyte tuckˑvˑb = tuckˑmodˑstr.byteAt(t, tuckˑvˑi);
        if (!tuckˑfnˑisSpaceByte(tuckˑvˑb)) {
            break;
        }
        tuckˑvˑi = (tuckˑvˑi + 1L);
    }
    long tuckˑvˑn = tuckˑmodˑstr.byteCount(t);
    rt.TuckResult!(string) tuckˑvˑout = tuckˑfnˑslice(t, tuckˑvˑi, tuckˑvˑn);
    scope(exit) rt.tuckDrop(tuckˑvˑout);
    if (!(tuckˑvˑout.status == rt.TuckStatus.Ok)) {
        return ("").idup;
    }
    string tuckOwnTmp3 = tuckˑvˑout.value;
    tuckˑvˑout.value = typeof(tuckˑvˑout.value).init;
    return tuckOwnTmp3;
}

string tuckˑfnˑtrimEnd(string t) {
    long tuckˑvˑn = tuckˑmodˑstr.byteCount(t);
    while ((tuckˑvˑn > 0L)) {
        ubyte tuckˑvˑb = tuckˑmodˑstr.byteAt(t, (tuckˑvˑn - 1L));
        if (!tuckˑfnˑisSpaceByte(tuckˑvˑb)) {
            break;
        }
        tuckˑvˑn = (tuckˑvˑn - 1L);
    }
    rt.TuckResult!(string) tuckˑvˑout = tuckˑfnˑslice(t, 0L, tuckˑvˑn);
    scope(exit) rt.tuckDrop(tuckˑvˑout);
    if (!(tuckˑvˑout.status == rt.TuckStatus.Ok)) {
        return ("").idup;
    }
    string tuckOwnTmp4 = tuckˑvˑout.value;
    tuckˑvˑout.value = typeof(tuckˑvˑout.value).init;
    return tuckOwnTmp4;
}

string tuckˑfnˑtrim(string t) {
    string tuckˑvˑhead = tuckˑfnˑtrimStart(t);
    scope(exit) rt.tuckDrop(tuckˑvˑhead);
    return tuckˑfnˑtrimEnd(tuckˑvˑhead);
}

ubyte tuckˑfnˑlowerByte(ubyte b) {
    long tuckˑvˑv = cast(long)(b);
    if (((tuckˑvˑv >= 65L) && (tuckˑvˑv <= 90L))) {
        return cast(ubyte)((tuckˑvˑv + 32L));
    }
    return b;
}

ubyte tuckˑfnˑupperByte(ubyte b) {
    long tuckˑvˑv = cast(long)(b);
    if (((tuckˑvˑv >= 97L) && (tuckˑvˑv <= 122L))) {
        return cast(ubyte)((tuckˑvˑv - 32L));
    }
    return b;
}

string tuckˑfnˑtoLowerAscii(string t) {
    ubyte[] tuckˑvˑout = tuckˑfnˑnoBytes();
    scope(exit) rt.tuckDrop(tuckˑvˑout);
    foreach (tuckˑvˑi; 0L .. (tuckˑmodˑstr.byteCount(t) - 1L) + 1) {
        ubyte tuckˑvˑb = tuckˑmodˑstr.byteAt(t, tuckˑvˑi);
        ubyte tuckˑvˑlow = tuckˑfnˑlowerByte(tuckˑvˑb);
        rt.tuckPush(tuckˑvˑout, tuckˑvˑlow);
    }
    return tuckˑmodˑstr.fromBytes(tuckˑvˑout);
}

string tuckˑfnˑtoUpperAscii(string t) {
    ubyte[] tuckˑvˑout = tuckˑfnˑnoBytes();
    scope(exit) rt.tuckDrop(tuckˑvˑout);
    foreach (tuckˑvˑi; 0L .. (tuckˑmodˑstr.byteCount(t) - 1L) + 1) {
        ubyte tuckˑvˑb = tuckˑmodˑstr.byteAt(t, tuckˑvˑi);
        ubyte tuckˑvˑup = tuckˑfnˑupperByte(tuckˑvˑb);
        rt.tuckPush(tuckˑvˑout, tuckˑvˑup);
    }
    return tuckˑmodˑstr.fromBytes(tuckˑvˑout);
}

long tuckˑfnˑcheckAscii() {
    if (!tuckˑfnˑisEmpty("")) {
        return 1L;
    }
    if (tuckˑfnˑisEmpty("a")) {
        return 2L;
    }
    rt.TuckResult!(tuckˑtypeˑChar) tuckˑvˑc = tuckˑfnˑcharAtByte("abc", 1L);
    if (!(tuckˑvˑc.status == rt.TuckStatus.Ok)) {
        return 3L;
    }
    if ((cast(long)(tuckˑvˑc.value) != 98L)) {
        return 4L;
    }
    rt.TuckResult!(tuckˑtypeˑChar) tuckˑvˑpast = tuckˑfnˑcharAtByte("abc", 9L);
    if ((tuckˑvˑpast.status == rt.TuckStatus.Ok)) {
        return 5L;
    }
    return tuckˑfnˑcheckSearch();
}

long tuckˑfnˑcheckSearch() {
    rt.TuckResult!(long) tuckˑvˑat = tuckˑfnˑfind("hello", "ll");
    if (!(tuckˑvˑat.status == rt.TuckStatus.Ok)) {
        return 6L;
    }
    if ((tuckˑvˑat.value != 2L)) {
        return 7L;
    }
    rt.TuckResult!(long) tuckˑvˑmissing = tuckˑfnˑfind("hello", "zz");
    if ((tuckˑvˑmissing.status == rt.TuckStatus.Ok)) {
        return 8L;
    }
    if (!tuckˑfnˑhas("hello", "ell")) {
        return 9L;
    }
    if (!tuckˑfnˑstartsWith("hello", "he")) {
        return 10L;
    }
    if (!tuckˑfnˑendsWith("hello", "lo")) {
        return 11L;
    }
    if (tuckˑfnˑendsWith("hi", "longer")) {
        return 12L;
    }
    return tuckˑfnˑcheckSliceSplit();
}

long tuckˑfnˑcheckSliceSplit() {
    rt.TuckResult!(string) tuckˑvˑs = tuckˑfnˑslice("hello", 1L, 3L);
    scope(exit) rt.tuckDrop(tuckˑvˑs);
    if (!(tuckˑvˑs.status == rt.TuckStatus.Ok)) {
        return 13L;
    }
    if ((tuckˑvˑs.value != "el")) {
        return 14L;
    }
    rt.TuckResult!(string) tuckˑvˑbad = tuckˑfnˑslice("hi", 0L, 99L);
    scope(exit) rt.tuckDrop(tuckˑvˑbad);
    if ((tuckˑvˑbad.status == rt.TuckStatus.Ok)) {
        return 15L;
    }
    string[] tuckˑvˑparts = tuckˑfnˑsplit(("a,b,c").idup, ",");
    scope(exit) rt.tuckDrop(tuckˑvˑparts);
    if ((tuckˑmodˑseq.count(tuckˑvˑparts) != 3L)) {
        return 16L;
    }
    if ((rt.tuckAt(tuckˑvˑparts, 0L) != "a")) {
        return 17L;
    }
    if ((rt.tuckAt(tuckˑvˑparts, 2L) != "c")) {
        return 18L;
    }
    return tuckˑfnˑcheckTrimCase();
}

long tuckˑfnˑcheckTrimCase() {
    string tuckOwnTmp5 = tuckˑfnˑtrim("  hi  ");
    scope(exit) rt.tuckDrop(tuckOwnTmp5);
    if ((tuckOwnTmp5 != "hi")) {
        return 19L;
    }
    string tuckOwnTmp6 = tuckˑfnˑtrimStart("  hi");
    scope(exit) rt.tuckDrop(tuckOwnTmp6);
    if ((tuckOwnTmp6 != "hi")) {
        return 20L;
    }
    string tuckOwnTmp7 = tuckˑfnˑtrimEnd("hi  ");
    scope(exit) rt.tuckDrop(tuckOwnTmp7);
    if ((tuckOwnTmp7 != "hi")) {
        return 21L;
    }
    string tuckOwnTmp8 = tuckˑfnˑtrim("   ");
    scope(exit) rt.tuckDrop(tuckOwnTmp8);
    if ((tuckOwnTmp8 != "")) {
        return 22L;
    }
    string tuckOwnTmp9 = tuckˑfnˑtoLowerAscii("AbC");
    scope(exit) rt.tuckDrop(tuckOwnTmp9);
    if ((tuckOwnTmp9 != "abc")) {
        return 23L;
    }
    string tuckOwnTmp10 = tuckˑfnˑtoUpperAscii("AbC");
    scope(exit) rt.tuckDrop(tuckOwnTmp10);
    if ((tuckOwnTmp10 != "ABC")) {
        return 24L;
    }
    return tuckˑfnˑcheckRunes();
}

long tuckˑfnˑcheckRunes() {
    string tuckˑvˑs = ("héllo").idup;
    scope(exit) rt.tuckDrop(tuckˑvˑs);
    if ((tuckˑmodˑstr.byteCount(tuckˑvˑs) != 6L)) {
        return 25L;
    }
    if ((tuckˑfnˑruneCount(tuckˑvˑs) != 5L)) {
        return 26L;
    }
    rt.TuckResult!(tuckˑtypeˑRune) tuckˑvˑr = tuckˑfnˑruneAt(tuckˑvˑs, 1L);
    if (!(tuckˑvˑr.status == rt.TuckStatus.Ok)) {
        return 27L;
    }
    if ((cast(long)(tuckˑvˑr.value) != 233L)) {
        return 28L;
    }
    tuckˑtypeˑRune[] tuckˑvˑrs = tuckˑfnˑrunes(tuckˑvˑs);
    scope(exit) rt.tuckDrop(tuckˑvˑrs);
    if ((tuckˑmodˑseq.count(tuckˑvˑrs) != 5L)) {
        return 29L;
    }
    tuckˑtypeˑRune[] tuckˑvˑrs2 = tuckˑfnˑrunes(tuckˑvˑs);
    scope(exit) rt.tuckDrop(tuckˑvˑrs2);
    string tuckOwnTmp11 = tuckˑfnˑfromRunes(tuckˑvˑrs2);
    scope(exit) rt.tuckDrop(tuckOwnTmp11);
    if ((tuckOwnTmp11 != tuckˑvˑs)) {
        return 30L;
    }
    return 0L;
}

long tuckˑfnˑmain() {
    return tuckˑfnˑcheckAscii();
}

