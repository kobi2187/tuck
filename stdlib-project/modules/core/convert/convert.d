module convert;

import rt = tuck_rt;
import str = mod_str;

long tuck_i64Max() {
    return 9223372036854775807L;
}

long tuck_i64Min() {
    return ((0L - tuck_i64Max()) - 1L);
}

long tuck_i32Max() {
    return 2147483647L;
}

long tuck_i32Min() {
    return ((0L - tuck_i32Max()) - 1L);
}

rt.TuckResult!(int) tuck_toNarrow(long x) {
    if (((x < tuck_i32Min()) || (x > tuck_i32Max()))) {
        return rt.tnone!(int)();
    }
    return rt.tok(cast(int)(x));
}

int tuck_toNarrowClamped(long x) {
    if ((x < tuck_i32Min())) {
        return cast(int)(tuck_i32Min());
    }
    if ((x > tuck_i32Max())) {
        return cast(int)(tuck_i32Max());
    }
    return cast(int)(x);
}

float tuck_toApprox(double x) {
    return cast(float)(x);
}

rt.TuckResult!(long) tuck_digitOf(string t, long index) {
    ubyte tuck_raw = str.byteAt(t, index);
    long tuck_b = cast(long)(tuck_raw);
    if (((tuck_b < 48L) || (tuck_b > 57L))) {
        return rt.tnone!(long)();
    }
    return rt.tok((tuck_b - 48L));
}

bool tuck_isSign(string t, long index) {
    ubyte tuck_raw = str.byteAt(t, index);
    long tuck_b = cast(long)(tuck_raw);
    return ((tuck_b == 43L) || (tuck_b == 45L));
}

bool tuck_isNegative(string t) {
    if ((str.byteCount(t) == 0L)) {
        return false;
    }
    ubyte tuck_lead = str.byteAt(t, 0L);
    return (cast(long)(tuck_lead) == 45L);
}

rt.TuckResult!(long) tuck_parseInt(string t) {
    long tuck_n = str.byteCount(t);
    if ((tuck_n == 0L)) {
        return rt.tnone!(long)();
    }
    long tuck_start = 0L;
    if (tuck_isSign(t, 0L)) {
        tuck_start = 1L;
    }
    if ((tuck_start >= tuck_n)) {
        return rt.tnone!(long)();
    }
    bool tuck_neg = tuck_isNegative(t);
    return tuck_accumulate(t, tuck_start, tuck_n, tuck_neg);
}

rt.TuckResult!(long) tuck_accumulate(string t, long start, long count, bool neg) {
    long tuck_acc = 0L;
    foreach (tuck_i; start .. (count - 1L) + 1) {
        rt.TuckResult!(long) tuck_d = tuck_digitOf(t, tuck_i);
        if (!(tuck_d.status == rt.TuckStatus.Ok)) {
            return rt.tnone!(long)();
        }
        rt.TuckResult!(long) tuck_step = tuck_addDigit(tuck_acc, tuck_d.value, neg);
        if (!(tuck_step.status == rt.TuckStatus.Ok)) {
            return rt.tnone!(long)();
        }
        tuck_acc = tuck_step.value;
    }
    return rt.tok(tuck_acc);
}

rt.TuckResult!(long) tuck_addDigit(long acc, long digit, bool neg) {
    long tuck_d = cast(long)(digit);
    if (neg) {
        if ((acc < ((tuck_i64Min() + tuck_d) / 10L))) {
            return rt.tnone!(long)();
        }
        return rt.tok(((acc * 10L) - tuck_d));
    }
    if ((acc > ((tuck_i64Max() - tuck_d) / 10L))) {
        return rt.tnone!(long)();
    }
    return rt.tok(((acc * 10L) + tuck_d));
}

long tuck_checkNarrow() {
    rt.TuckResult!(int) tuck_ok = tuck_toNarrow(1000L);
    if (!(tuck_ok.status == rt.TuckStatus.Ok)) {
        return 1L;
    }
    if ((cast(long)(tuck_ok.value) != 1000L)) {
        return 2L;
    }
    rt.TuckResult!(int) tuck_past = tuck_toNarrow(3000000000L);
    if ((tuck_past.status == rt.TuckStatus.Ok)) {
        return 3L;
    }
    int tuck_hi = tuck_toNarrowClamped(3000000000L);
    if ((cast(long)(tuck_hi) != tuck_i32Max())) {
        return 4L;
    }
    int tuck_lo = tuck_toNarrowClamped((0L - 3000000000L));
    if ((cast(long)(tuck_lo) != tuck_i32Min())) {
        return 5L;
    }
    return tuck_checkParseOk();
}

long tuck_checkParseOk() {
    rt.TuckResult!(long) tuck_a = tuck_parseInt("123");
    if (!(tuck_a.status == rt.TuckStatus.Ok)) {
        return 6L;
    }
    if ((tuck_a.value != 123L)) {
        return 7L;
    }
    rt.TuckResult!(long) tuck_b = tuck_parseInt("-45");
    if (!(tuck_b.status == rt.TuckStatus.Ok)) {
        return 8L;
    }
    if ((tuck_b.value != (0L - 45L))) {
        return 9L;
    }
    rt.TuckResult!(long) tuck_c = tuck_parseInt("+7");
    if (!(tuck_c.status == rt.TuckStatus.Ok)) {
        return 10L;
    }
    if ((tuck_c.value != 7L)) {
        return 11L;
    }
    return tuck_checkParseEdges();
}

long tuck_checkParseEdges() {
    rt.TuckResult!(long) tuck_lo = tuck_parseInt("-9223372036854775808");
    if (!(tuck_lo.status == rt.TuckStatus.Ok)) {
        return 12L;
    }
    if ((tuck_lo.value != tuck_i64Min())) {
        return 13L;
    }
    rt.TuckResult!(long) tuck_hi = tuck_parseInt("9223372036854775807");
    if (!(tuck_hi.status == rt.TuckStatus.Ok)) {
        return 14L;
    }
    if ((tuck_hi.value != tuck_i64Max())) {
        return 15L;
    }
    rt.TuckResult!(long) tuck_over = tuck_parseInt("9223372036854775808");
    if ((tuck_over.status == rt.TuckStatus.Ok)) {
        return 16L;
    }
    return tuck_checkParseBad();
}

long tuck_checkParseBad() {
    rt.TuckResult!(long) tuck_empty = tuck_parseInt("");
    if ((tuck_empty.status == rt.TuckStatus.Ok)) {
        return 17L;
    }
    rt.TuckResult!(long) tuck_lone = tuck_parseInt("-");
    if ((tuck_lone.status == rt.TuckStatus.Ok)) {
        return 18L;
    }
    rt.TuckResult!(long) tuck_trailing = tuck_parseInt("12x");
    if ((tuck_trailing.status == rt.TuckStatus.Ok)) {
        return 19L;
    }
    rt.TuckResult!(long) tuck_letters = tuck_parseInt("x");
    if ((tuck_letters.status == rt.TuckStatus.Ok)) {
        return 20L;
    }
    return 0L;
}

long tuck_main() {
    return tuck_checkNarrow();
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_main();
    return cast(int) mainRc;
}
