module mod_convert;

import rt = tuck_rt;
import tuckˑmodˑstr = mod_str;

long tuckˑfnˑi64Max() {
    return 9223372036854775807L;
}

long tuckˑfnˑi64Min() {
    return ((0L - tuckˑfnˑi64Max()) - 1L);
}

long tuckˑfnˑi32Max() {
    return 2147483647L;
}

long tuckˑfnˑi32Min() {
    return ((0L - tuckˑfnˑi32Max()) - 1L);
}

rt.TuckResult!(int) tuckˑfnˑtoNarrow(long x) {
    if (((x < tuckˑfnˑi32Min()) || (x > tuckˑfnˑi32Max()))) {
        return rt.tnone!(int)();
    }
    return rt.tok(cast(int)(x));
}

int tuckˑfnˑtoNarrowClamped(long x) {
    if ((x < tuckˑfnˑi32Min())) {
        return cast(int)(tuckˑfnˑi32Min());
    }
    if ((x > tuckˑfnˑi32Max())) {
        return cast(int)(tuckˑfnˑi32Max());
    }
    return cast(int)(x);
}

float tuckˑfnˑtoApprox(double x) {
    return cast(float)(x);
}

rt.TuckResult!(long) tuckˑfnˑdigitOf(string t, long index) {
    ubyte tuckˑvˑraw = tuckˑmodˑstr.byteAt(t, index);
    long tuckˑvˑb = cast(long)(tuckˑvˑraw);
    if (((tuckˑvˑb < 48L) || (tuckˑvˑb > 57L))) {
        return rt.tnone!(long)();
    }
    return rt.tok((tuckˑvˑb - 48L));
}

bool tuckˑfnˑisSign(string t, long index) {
    ubyte tuckˑvˑraw = tuckˑmodˑstr.byteAt(t, index);
    long tuckˑvˑb = cast(long)(tuckˑvˑraw);
    return ((tuckˑvˑb == 43L) || (tuckˑvˑb == 45L));
}

bool tuckˑfnˑisNegative(string t) {
    if ((tuckˑmodˑstr.byteCount(t) == 0L)) {
        return false;
    }
    ubyte tuckˑvˑlead = tuckˑmodˑstr.byteAt(t, 0L);
    return (cast(long)(tuckˑvˑlead) == 45L);
}

rt.TuckResult!(long) tuckˑfnˑparseInt(string t) {
    long tuckˑvˑn = tuckˑmodˑstr.byteCount(t);
    if ((tuckˑvˑn == 0L)) {
        return rt.tnone!(long)();
    }
    long tuckˑvˑstart = 0L;
    if (tuckˑfnˑisSign(t, 0L)) {
        tuckˑvˑstart = 1L;
    }
    if ((tuckˑvˑstart >= tuckˑvˑn)) {
        return rt.tnone!(long)();
    }
    bool tuckˑvˑneg = tuckˑfnˑisNegative(t);
    return tuckˑfnˑaccumulate(t, tuckˑvˑstart, tuckˑvˑn, tuckˑvˑneg);
}

rt.TuckResult!(long) tuckˑfnˑaccumulate(string t, long start, long count, bool neg) {
    long tuckˑvˑacc = 0L;
    foreach (tuckˑvˑi; start .. (count - 1L) + 1) {
        rt.TuckResult!(long) tuckˑvˑd = tuckˑfnˑdigitOf(t, tuckˑvˑi);
        if (!(tuckˑvˑd.status == rt.TuckStatus.Ok)) {
            return rt.tnone!(long)();
        }
        rt.TuckResult!(long) tuckˑvˑstep = tuckˑfnˑaddDigit(tuckˑvˑacc, tuckˑvˑd.value, neg);
        if (!(tuckˑvˑstep.status == rt.TuckStatus.Ok)) {
            return rt.tnone!(long)();
        }
        tuckˑvˑacc = tuckˑvˑstep.value;
    }
    return rt.tok(tuckˑvˑacc);
}

rt.TuckResult!(long) tuckˑfnˑaddDigit(long acc, long digit, bool neg) {
    long tuckˑvˑd = cast(long)(digit);
    if (neg) {
        if ((acc < ((tuckˑfnˑi64Min() + tuckˑvˑd) / 10L))) {
            return rt.tnone!(long)();
        }
        return rt.tok(((acc * 10L) - tuckˑvˑd));
    }
    if ((acc > ((tuckˑfnˑi64Max() - tuckˑvˑd) / 10L))) {
        return rt.tnone!(long)();
    }
    return rt.tok(((acc * 10L) + tuckˑvˑd));
}

long tuckˑfnˑcheckNarrow() {
    rt.TuckResult!(int) tuckˑvˑok = tuckˑfnˑtoNarrow(1000L);
    if (!(tuckˑvˑok.status == rt.TuckStatus.Ok)) {
        return 1L;
    }
    if ((cast(long)(tuckˑvˑok.value) != 1000L)) {
        return 2L;
    }
    rt.TuckResult!(int) tuckˑvˑpast = tuckˑfnˑtoNarrow(3000000000L);
    if ((tuckˑvˑpast.status == rt.TuckStatus.Ok)) {
        return 3L;
    }
    int tuckˑvˑhi = tuckˑfnˑtoNarrowClamped(3000000000L);
    if ((cast(long)(tuckˑvˑhi) != tuckˑfnˑi32Max())) {
        return 4L;
    }
    int tuckˑvˑlo = tuckˑfnˑtoNarrowClamped((0L - 3000000000L));
    if ((cast(long)(tuckˑvˑlo) != tuckˑfnˑi32Min())) {
        return 5L;
    }
    return tuckˑfnˑcheckParseOk();
}

long tuckˑfnˑcheckParseOk() {
    rt.TuckResult!(long) tuckˑvˑa = tuckˑfnˑparseInt("123");
    if (!(tuckˑvˑa.status == rt.TuckStatus.Ok)) {
        return 6L;
    }
    if ((tuckˑvˑa.value != 123L)) {
        return 7L;
    }
    rt.TuckResult!(long) tuckˑvˑb = tuckˑfnˑparseInt("-45");
    if (!(tuckˑvˑb.status == rt.TuckStatus.Ok)) {
        return 8L;
    }
    if ((tuckˑvˑb.value != (0L - 45L))) {
        return 9L;
    }
    rt.TuckResult!(long) tuckˑvˑc = tuckˑfnˑparseInt("+7");
    if (!(tuckˑvˑc.status == rt.TuckStatus.Ok)) {
        return 10L;
    }
    if ((tuckˑvˑc.value != 7L)) {
        return 11L;
    }
    return tuckˑfnˑcheckParseEdges();
}

long tuckˑfnˑcheckParseEdges() {
    rt.TuckResult!(long) tuckˑvˑlo = tuckˑfnˑparseInt("-9223372036854775808");
    if (!(tuckˑvˑlo.status == rt.TuckStatus.Ok)) {
        return 12L;
    }
    if ((tuckˑvˑlo.value != tuckˑfnˑi64Min())) {
        return 13L;
    }
    rt.TuckResult!(long) tuckˑvˑhi = tuckˑfnˑparseInt("9223372036854775807");
    if (!(tuckˑvˑhi.status == rt.TuckStatus.Ok)) {
        return 14L;
    }
    if ((tuckˑvˑhi.value != tuckˑfnˑi64Max())) {
        return 15L;
    }
    rt.TuckResult!(long) tuckˑvˑover = tuckˑfnˑparseInt("9223372036854775808");
    if ((tuckˑvˑover.status == rt.TuckStatus.Ok)) {
        return 16L;
    }
    return tuckˑfnˑcheckParseBad();
}

long tuckˑfnˑcheckParseBad() {
    rt.TuckResult!(long) tuckˑvˑempty = tuckˑfnˑparseInt("");
    if ((tuckˑvˑempty.status == rt.TuckStatus.Ok)) {
        return 17L;
    }
    rt.TuckResult!(long) tuckˑvˑlone = tuckˑfnˑparseInt("-");
    if ((tuckˑvˑlone.status == rt.TuckStatus.Ok)) {
        return 18L;
    }
    rt.TuckResult!(long) tuckˑvˑtrailing = tuckˑfnˑparseInt("12x");
    if ((tuckˑvˑtrailing.status == rt.TuckStatus.Ok)) {
        return 19L;
    }
    rt.TuckResult!(long) tuckˑvˑletters = tuckˑfnˑparseInt("x");
    if ((tuckˑvˑletters.status == rt.TuckStatus.Ok)) {
        return 20L;
    }
    return 0L;
}

long tuckˑfnˑmain() {
    return tuckˑfnˑcheckNarrow();
}

