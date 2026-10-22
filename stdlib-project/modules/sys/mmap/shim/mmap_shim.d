// D impl module for stdlib-project sys.mmap — the twin of mmap_shim.nim.
//
// Same contract: the mapping's address stays here, a HANDLE crosses, and every
// operation on the mapped bytes runs in this file. Only `mapCopy` hands bytes
// over, and only the window asked for.
module mmap_shim;

import core.sys.posix.fcntl : open, O_RDONLY;
import core.sys.posix.unistd : close;
import core.sys.posix.sys.stat : stat_t, fstat;
import core.sys.posix.sys.mman : mmap, munmap, PROT_READ, MAP_PRIVATE, MAP_FAILED;
import core.stdc.errno : errno, ENOENT, ENOTDIR, EACCES, EPERM;
import std.string : toStringz;

private struct Mapping
{
    ubyte* base;
    long size;
    bool live;
}

private __gshared Mapping[] gMaps;

// -1 not found, -2 access denied, -3 anything else.
private long errnoCode()
{
    auto e = errno;
    if (e == ENOENT || e == ENOTDIR) return -1;
    if (e == EACCES || e == EPERM) return -2;
    return -3;
}

private bool valid(long handle)
{
    return handle >= 0 && handle < gMaps.length && gMaps[cast(size_t) handle].live;
}

/// A read-only, private mapping of the whole file: a handle >= 0, or a
/// negative code. An empty file maps to no memory (mmap refuses a zero length).
long mapOpen(string path)
{
    int fd = open(toStringz(path), O_RDONLY);
    if (fd < 0) return errnoCode();
    scope (exit) close(fd);
    stat_t st;
    if (fstat(fd, &st) != 0) return errnoCode();
    long size = cast(long) st.st_size;
    ubyte* base = null;
    if (size > 0)
    {
        auto p = mmap(null, cast(size_t) size, PROT_READ, MAP_PRIVATE, fd, 0);
        if (p == MAP_FAILED) return errnoCode();
        base = cast(ubyte*) p;
    }
    gMaps ~= Mapping(base, size, true);
    return cast(long) gMaps.length - 1;
}

long mapSize(long handle)
{
    if (!valid(handle)) return -1;
    return gMaps[cast(size_t) handle].size;
}

void mapClose(long handle)
{
    if (!valid(handle)) return;
    auto m = &gMaps[cast(size_t) handle];
    if (m.size > 0) munmap(m.base, cast(size_t) m.size);
    m.live = false;
}

/// The byte at `at`, or -1 outside the mapping.
long mapByte(long handle, long at)
{
    if (!valid(handle)) return -1;
    auto m = gMaps[cast(size_t) handle];
    if (at < 0 || at >= m.size) return -1;
    return m.base[cast(size_t) at];
}

/// The first offset >= `start` where `what` begins, or -1.
long mapFind(long handle, string what, long start)
{
    if (!valid(handle) || what.length == 0) return -1;
    auto m = gMaps[cast(size_t) handle];
    for (long i = start < 0 ? 0 : start; i + cast(long) what.length <= m.size; i++)
    {
        if (m.base[cast(size_t) i] != cast(ubyte) what[0]) continue;
        size_t k = 1;
        while (k < what.length && m.base[cast(size_t) i + k] == cast(ubyte) what[k]) k++;
        if (k == what.length) return i;
    }
    return -1;
}

/// How many bytes equal `value`.
long mapCount(long handle, long value)
{
    if (!valid(handle)) return 0;
    auto m = gMaps[cast(size_t) handle];
    long n = 0;
    foreach (i; 0 .. cast(size_t) m.size)
        if (m.base[i] == value) n++;
    return n;
}

/// How many bytes in [start, start + n) equal `value`, clamped.
long mapCountRange(long handle, long value, long start, long n)
{
    if (!valid(handle)) return 0;
    auto m = gMaps[cast(size_t) handle];
    long a = start < 0 ? 0 : start;
    long b = start + n < m.size ? start + n : m.size;
    long c = 0;
    for (long i = a; i < b; i++)
        if (m.base[cast(size_t) i] == value) c++;
    return c;
}

/// A copy of [start, start + n), clamped to the mapping.
ubyte[] mapCopy(long handle, long start, long n)
{
    if (!valid(handle)) return [];
    auto m = gMaps[cast(size_t) handle];
    long a = start < 0 ? 0 : start;
    long b = start + n < m.size ? start + n : m.size;
    if (b <= a) return [];
    return m.base[cast(size_t) a .. cast(size_t) b].dup;
}
