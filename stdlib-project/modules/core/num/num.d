module num;

import rt = tuck_rt;
import bits = mod_bits;

enum tuck_ByteOrder { Big, Little }

long tuck_i64Max() {
    return 9223372036854775807L;
}

long tuck_i64Min() {
    return ((0L - tuck_i64Max()) - 1L);
}

rt.TuckResult!(long) tuck_tryAdd(long a, long b) {
    if (((b > 0L) && (a > (tuck_i64Max() - b)))) {
        return rt.tnone!(long)();
    }
    if (((b < 0L) && (a < (tuck_i64Min() - b)))) {
        return rt.tnone!(long)();
    }
    return rt.tok((a + b));
}

rt.TuckResult!(long) tuck_trySub(long a, long b) {
    if (((b < 0L) && (a > (tuck_i64Max() + b)))) {
        return rt.tnone!(long)();
    }
    if (((b > 0L) && (a < (tuck_i64Min() + b)))) {
        return rt.tnone!(long)();
    }
    return rt.tok((a - b));
}

bool tuck_mulFits(long a, long b) {
    if ((a > 0L)) {
        if ((b > 0L)) {
            return (a <= (tuck_i64Max() / b));
        }
        return (b >= (tuck_i64Min() / a));
    }
    if ((b > 0L)) {
        return (a >= (tuck_i64Min() / b));
    }
    return (a >= (tuck_i64Max() / b));
}

rt.TuckResult!(long) tuck_tryMul(long a, long b) {
    if (((a == 0L) || (b == 0L))) {
        return rt.tok(0L);
    }
    if (!tuck_mulFits(a, b)) {
        return rt.tnone!(long)();
    }
    return rt.tok((a * b));
}

rt.TuckResult!(long) tuck_tryDiv(long a, long b) {
    if ((b == 0L)) {
        return rt.tnone!(long)();
    }
    if (((a == tuck_i64Min()) && (b == (0L - 1L)))) {
        return rt.tnone!(long)();
    }
    return rt.tok((a / b));
}

long tuck_sign(long x) {
    if ((x > 0L)) {
        return 1L;
    }
    if ((x < 0L)) {
        return (0L - 1L);
    }
    return 0L;
}

rt.TuckResult!(long) tuck_absI64(long x) {
    if ((x == tuck_i64Min())) {
        return rt.tnone!(long)();
    }
    if ((x < 0L)) {
        return rt.tok((0L - x));
    }
    return rt.tok(x);
}

ulong tuck_midpoint(ulong a, ulong b) {
    ulong tuck_xored = bits.bitXor(a, b);
    ulong tuck_halfXor = bits.shiftRight(tuck_xored, 1L);
    return (bits.bitAnd(a, b) + tuck_halfXor);
}

ulong tuck_bitMask(long at) {
    return bits.shiftLeft(1L, at);
}

bool tuck_hasBit(ulong x, long at) {
    ulong tuck_mask = tuck_bitMask(at);
    return (bits.bitAnd(x, tuck_mask) != 0L);
}

ulong tuck_withBit(ulong x, long at) {
    ulong tuck_mask = tuck_bitMask(at);
    return bits.bitOr(x, tuck_mask);
}

ulong tuck_withoutBit(ulong x, long at) {
    ulong tuck_mask = tuck_bitMask(at);
    ulong tuck_keep = bits.bitNot(tuck_mask);
    return bits.bitAnd(x, tuck_keep);
}

ulong tuck_flipBit(ulong x, long at) {
    ulong tuck_mask = tuck_bitMask(at);
    return bits.bitXor(x, tuck_mask);
}

long tuck_countBits(ulong x) {
    long tuck_n = 0L;
    foreach (tuck_i; 0L .. 63L + 1) {
        if (tuck_hasBit(x, tuck_i)) {
            tuck_n = (tuck_n + 1L);
        }
    }
    return tuck_n;
}

rt.TuckResult!(long) tuck_lowestSetBit(ulong x) {
    foreach (tuck_i; 0L .. 63L + 1) {
        if (tuck_hasBit(x, tuck_i)) {
            return rt.tok(tuck_i);
        }
    }
    return rt.tnone!(long)();
}

rt.TuckResult!(long) tuck_highestSetBit(ulong x) {
    long tuck_best = (0L - 1L);
    foreach (tuck_i; 0L .. 63L + 1) {
        if (tuck_hasBit(x, tuck_i)) {
            tuck_best = tuck_i;
        }
    }
    if ((tuck_best < 0L)) {
        return rt.tnone!(long)();
    }
    return rt.tok(tuck_best);
}

rt.TuckResult!(long) tuck_onlyBit(ulong x) {
    if ((tuck_countBits(x) != 1L)) {
        return rt.tnone!(long)();
    }
    foreach (tuck_i; 0L .. 63L + 1) {
        if (tuck_hasBit(x, tuck_i)) {
            return rt.tok(tuck_i);
        }
    }
    return rt.tnone!(long)();
}

long[] tuck_setBits(ulong x) {
    long[] tuck_acc = [];
    foreach (tuck_i; 0L .. 63L + 1) {
        if (tuck_hasBit(x, tuck_i)) {
            tuck_acc ~= tuck_i;
        }
    }
    return tuck_acc;
}

long tuck_shiftFor(tuck_ByteOrder order, long index) {
    final switch (order) {
    case tuck_ByteOrder.Big:
        return (56L - (index * 8L));
    case tuck_ByteOrder.Little:
        return (index * 8L);
    }
    return typeof(return).init;
}

ubyte tuck_byteAt(ulong value, long shift) {
    ulong tuck_moved = bits.shiftRight(value, shift);
    ulong tuck_low = bits.bitAnd(tuck_moved, 255L);
    return cast(ubyte)(tuck_low);
}

ubyte[] tuck_toBytes(ulong value, tuck_ByteOrder order) {
    ubyte[] tuck_acc = [];
    foreach (tuck_i; 0L .. 7L + 1) {
        long tuck_shift = tuck_shiftFor(order, tuck_i);
        ubyte tuck_b = tuck_byteAt(value, tuck_shift);
        tuck_acc ~= tuck_b;
    }
    return tuck_acc;
}

rt.TuckResult!(ulong) tuck_fromBytes(ubyte[] bytes, tuck_ByteOrder order) {
    if ((cast(long) bytes.length != 8L)) {
        return rt.tnone!(ulong)();
    }
    ulong tuck_acc = 0L;
    foreach (tuck_i; 0L .. 7L + 1) {
        ulong tuck_octet = cast(ulong)(rt.tuckAt(bytes, tuck_i));
        long tuck_shift = tuck_shiftFor(order, tuck_i);
        ulong tuck_placed = bits.shiftLeft(tuck_octet, tuck_shift);
        tuck_acc = bits.bitOr(tuck_acc, tuck_placed);
    }
    return rt.tok(tuck_acc);
}

long tuck_checkArith() {
    rt.TuckResult!(long) tuck_over = tuck_tryAdd(tuck_i64Max(), 1L);
    if ((tuck_over.status == rt.TuckStatus.Ok)) {
        return 1L;
    }
    rt.TuckResult!(long) tuck_fine = tuck_tryAdd(tuck_i64Max(), (0L - 1L));
    if (!(tuck_fine.status == rt.TuckStatus.Ok)) {
        return 2L;
    }
    if ((tuck_fine.value != (tuck_i64Max() - 1L))) {
        return 3L;
    }
    return tuck_checkArithRest();
}

long tuck_checkArithRest() {
    rt.TuckResult!(long) tuck_under = tuck_trySub(tuck_i64Min(), 1L);
    if ((tuck_under.status == rt.TuckStatus.Ok)) {
        return 4L;
    }
    rt.TuckResult!(long) tuck_big2 = tuck_tryMul(tuck_i64Max(), 2L);
    if ((tuck_big2.status == rt.TuckStatus.Ok)) {
        return 5L;
    }
    rt.TuckResult!(long) tuck_negMin = tuck_tryMul(tuck_i64Min(), (0L - 1L));
    if ((tuck_negMin.status == rt.TuckStatus.Ok)) {
        return 6L;
    }
    return tuck_checkDiv();
}

long tuck_checkDiv() {
    rt.TuckResult!(long) tuck_prod = tuck_tryMul(3L, 4L);
    if (!(tuck_prod.status == rt.TuckStatus.Ok)) {
        return 7L;
    }
    if ((tuck_prod.value != 12L)) {
        return 8L;
    }
    rt.TuckResult!(long) tuck_byZero = tuck_tryDiv(1L, 0L);
    if ((tuck_byZero.status == rt.TuckStatus.Ok)) {
        return 9L;
    }
    rt.TuckResult!(long) tuck_q = tuck_tryDiv(7L, 2L);
    if (!(tuck_q.status == rt.TuckStatus.Ok)) {
        return 10L;
    }
    if ((tuck_q.value != 3L)) {
        return 11L;
    }
    return 0L;
}

ulong tuck_threeFlags() {
    ulong tuck_flags = 0L;
    tuck_flags = tuck_withBit(tuck_flags, 0L);
    tuck_flags = tuck_withBit(tuck_flags, 5L);
    return tuck_withBit(tuck_flags, 63L);
}

long tuck_checkBits() {
    ulong tuck_flags = tuck_threeFlags();
    if ((tuck_countBits(tuck_flags) != 3L)) {
        return 12L;
    }
    if (!tuck_hasBit(tuck_flags, 5L)) {
        return 13L;
    }
    if (tuck_hasBit(tuck_flags, 4L)) {
        return 14L;
    }
    return tuck_checkBitSearch(tuck_flags);
}

long tuck_checkBitSearch(ulong flags) {
    rt.TuckResult!(long) tuck_lo = tuck_lowestSetBit(flags);
    if (!(tuck_lo.status == rt.TuckStatus.Ok)) {
        return 15L;
    }
    if ((tuck_lo.value != 0L)) {
        return 16L;
    }
    rt.TuckResult!(long) tuck_hi = tuck_highestSetBit(flags);
    if (!(tuck_hi.status == rt.TuckStatus.Ok)) {
        return 17L;
    }
    if ((tuck_hi.value != 63L)) {
        return 18L;
    }
    return tuck_checkBitSets(flags);
}

long tuck_checkBitSets(ulong flags) {
    long[] tuck_positions = (tuck_setBits(flags)).dup;
    if ((cast(long) tuck_positions.length != 3L)) {
        return 19L;
    }
    rt.TuckResult!(long) tuck_several = tuck_onlyBit(flags);
    if ((tuck_several.status == rt.TuckStatus.Ok)) {
        return 20L;
    }
    return tuck_checkOneBit();
}

long tuck_checkOneBit() {
    ulong tuck_zero = cast(ulong)(0L);
    ulong tuck_one = tuck_withBit(tuck_zero, 7L);
    rt.TuckResult!(long) tuck_only = tuck_onlyBit(tuck_one);
    if (!(tuck_only.status == rt.TuckStatus.Ok)) {
        return 21L;
    }
    if ((tuck_only.value != 7L)) {
        return 22L;
    }
    return tuck_checkBitUndo(tuck_one);
}

long tuck_checkBitUndo(ulong one) {
    ulong tuck_cleared = tuck_withoutBit(one, 7L);
    if ((tuck_countBits(tuck_cleared) != 0L)) {
        return 23L;
    }
    ulong tuck_flipped = tuck_flipBit(one, 7L);
    if ((tuck_countBits(tuck_flipped) != 0L)) {
        return 24L;
    }
    ulong tuck_none0 = cast(ulong)(0L);
    rt.TuckResult!(long) tuck_empty = tuck_lowestSetBit(tuck_none0);
    if ((tuck_empty.status == rt.TuckStatus.Ok)) {
        return 25L;
    }
    return 0L;
}

long tuck_checkBytes() {
    ulong tuck_v = cast(ulong)(258L);
    ubyte[] tuck_big = (tuck_toBytes(tuck_v, tuck_ByteOrder.Big)).dup;
    if ((cast(long) tuck_big.length != 8L)) {
        return 26L;
    }
    if ((rt.tuckAt(tuck_big, 7L) != cast(ubyte)(2L))) {
        return 27L;
    }
    ubyte[] tuck_little = (tuck_toBytes(tuck_v, tuck_ByteOrder.Little)).dup;
    if ((rt.tuckAt(tuck_little, 0L) != cast(ubyte)(2L))) {
        return 28L;
    }
    return tuck_checkRoundTrip(tuck_v, tuck_big);
}

long tuck_checkRoundTrip(ulong v, ubyte[] big) {
    rt.TuckResult!(ulong) tuck_back = tuck_fromBytes(big, tuck_ByteOrder.Big);
    if (!(tuck_back.status == rt.TuckStatus.Ok)) {
        return 29L;
    }
    if ((tuck_back.value != v)) {
        return 30L;
    }
    ubyte[] tuck_oneByte = [cast(ubyte)(1L)];
    rt.TuckResult!(ulong) tuck_short = tuck_fromBytes(tuck_oneByte, tuck_ByteOrder.Big);
    if ((tuck_short.status == rt.TuckStatus.Ok)) {
        return 31L;
    }
    return 0L;
}

long tuck_checkSignAndMid() {
    if ((tuck_sign(5L) != 1L)) {
        return 40L;
    }
    if ((tuck_sign((0L - 5L)) != (0L - 1L))) {
        return 41L;
    }
    if ((tuck_sign(0L) != 0L)) {
        return 42L;
    }
    rt.TuckResult!(long) tuck_a5 = tuck_absI64((0L - 5L));
    if (!(tuck_a5.status == rt.TuckStatus.Ok)) {
        return 43L;
    }
    if ((tuck_a5.value != 5L)) {
        return 43L;
    }
    rt.TuckResult!(long) tuck_absent = tuck_absI64(tuck_i64Min());
    if ((tuck_absent.status == rt.TuckStatus.Ok)) {
        return 44L;
    }
    if ((tuck_midpoint(4L, 10L) != 7L)) {
        return 45L;
    }
    ulong tuck_near = bits.bitNot(0L);
    if ((tuck_midpoint(tuck_near, tuck_near) != tuck_near)) {
        return 46L;
    }
    return 0L;
}

long tuck_main() {
    long tuck_arith = tuck_checkArith();
    if ((tuck_arith != 0L)) {
        return tuck_arith;
    }
    long tuck_bits = tuck_checkBits();
    if ((tuck_bits != 0L)) {
        return tuck_bits;
    }
    long tuck_bytes = tuck_checkBytes();
    if ((tuck_bytes != 0L)) {
        return tuck_bytes;
    }
    return tuck_checkSignAndMid();
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_main();
    return cast(int) mainRc;
}
