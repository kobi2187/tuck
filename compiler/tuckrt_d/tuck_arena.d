/// THE SEQ ARENA — small blocks for the Seqs the ownership rules allocate and
/// free by hand.
///
/// Tuck's D backend frees every block itself (the collector is disabled), yet
/// every allocation and every free still went through the collector: a lock, a
/// pool search, a block-info lookup, an atomic. Measured with callgrind, about
/// 340 instructions to allocate and ~250 to free one block: 58% of the sum-type
/// binary-trees, 36% of fannkuch. A block this module hands out costs a lock
/// word and a list pop.
///
/// HOW IT STAYS HONEST. One reserved range of address space, cut into one
/// segment per size class. A pointer's class is `(p - base) / SegBytes`, so no
/// block carries a header, and "is this ours?" is a range check. Anything the
/// arena did not hand out (a literal, a library's array, a block over 4 KB, an
/// interior slice) is not ours: `tuckArenaFree` answers false and the caller
/// frees it the way it always did. Capacity falls out of the class, which is
/// what lets a push extend in place without asking the collector.
///
/// Thread-safe: actors run on their own OS threads, so each class has a
/// spinlock around a list pop or a bump.
module tuck_arena;

import core.atomic : atomicStore, atomicLoad, cas, MemoryOrder;
import core.sys.posix.sys.mman : mmap, PROT_READ, PROT_WRITE, MAP_PRIVATE,
    MAP_ANON, MAP_FAILED;

// druntime does not export it; the value is Linux's (0 elsewhere: the range is
// then charged to the commit limit, and the arena may simply fail to reserve).
version (linux) private enum int MAP_NORESERVE = 0x4000;
else private enum int MAP_NORESERVE = 0;

private enum size_t SegBytes = 256UL << 20;       // virtual, untouched until used
private immutable size_t[24] ClassBytes = [
    16, 32, 48, 64, 80, 96, 112, 128, 160, 192, 224, 256,
    320, 384, 448, 512, 640, 768, 896, 1024, 1536, 2048, 3072, 4096];
private enum size_t MaxSmall = 4096;
private enum size_t Classes = ClassBytes.length;

private struct Seg
{
    shared int lock;
    ubyte* bump;
    ubyte* end;
    void* free;
}

private __gshared ubyte* base;
private __gshared Seg[Classes] segs;
private __gshared ubyte[MaxSmall / 16 + 1] classOf;   // (bytes + 15) / 16 -> class

/// Reserve the range and fill the class table. A failed reservation leaves the
/// arena off: every call then answers "not ours" and the collector serves.
void tuckArenaInit()
{
    if (base !is null) return;
    size_t c = 0;
    foreach (i; 0 .. classOf.length)
    {
        while (ClassBytes[c] < i * 16) ++c;
        classOf[i] = cast(ubyte) c;
    }
    auto p = mmap(null, SegBytes * Classes, PROT_READ | PROT_WRITE,
                  MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
    if (p is MAP_FAILED) return;
    foreach (i; 0 .. Classes)
    {
        segs[i].bump = cast(ubyte*) p + i * SegBytes;
        segs[i].end = segs[i].bump + SegBytes;
    }
    base = cast(ubyte*) p;
}

private void lockSeg(ref Seg s) nothrow @nogc
{
    while (!cas!(MemoryOrder.acq, MemoryOrder.raw)(&s.lock, 0, 1)) {}
}

private void unlockSeg(ref Seg s) nothrow @nogc
{
    atomicStore!(MemoryOrder.rel)(s.lock, 0);
}

/// A block of at least `bytes` (a multiple of 16, uninitialised), or null when
/// it is too big for the arena, the segment is spent, or the arena is off.
void* tuckArenaAlloc(size_t bytes) nothrow @nogc
{
    if (base is null || bytes == 0 || bytes > MaxSmall) return null;
    immutable c = classOf[(bytes + 15) >> 4];
    auto s = &segs[c];
    lockSeg(*s);
    void* p = s.free;
    if (p !is null)
        s.free = *cast(void**) p;
    else if (s.bump + ClassBytes[c] <= s.end)
    {
        p = s.bump;
        s.bump += ClassBytes[c];
    }
    unlockSeg(*s);
    return p;
}

/// How many bytes the block starting at `p` can hold, or 0 when `p` is not the
/// start of an arena block (null, the collector's, a literal, an interior slice).
size_t tuckArenaCapacity(const(void)* p) nothrow @nogc
{
    immutable off = cast(size_t)(cast(const(ubyte)*) p - base);
    if (base is null || off >= SegBytes * Classes) return 0;
    immutable c = off / SegBytes;
    if ((off % SegBytes) % ClassBytes[c] != 0) return 0;
    return ClassBytes[c];
}

/// Is `p` anywhere inside the arena (a block start or not)?
bool tuckArenaContains(const(void)* p) nothrow @nogc
{
    immutable off = cast(size_t)(cast(const(ubyte)*) p - base);
    return base !is null && off < SegBytes * Classes;
}

/// Give back the block starting at `p`. True when the arena owned the pointer,
/// whether or not it freed anything (an interior slice is the owner's block's
/// business and is left alone); false when it is not the arena's at all.
bool tuckArenaFree(void* p) nothrow @nogc
{
    if (!tuckArenaContains(p)) return false;
    immutable off = cast(size_t)(cast(ubyte*) p - base);
    immutable c = off / SegBytes;
    if ((off % SegBytes) % ClassBytes[c] != 0) return true;
    auto s = &segs[c];
    lockSeg(*s);
    *cast(void**) p = s.free;
    s.free = p;
    unlockSeg(*s);
    return true;
}
