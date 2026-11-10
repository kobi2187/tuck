// D impl module for core.mem's secret buffers — the twin of secret_shim.nim.
module secret_shim;

private extern (C) nothrow @nogc
{
    void explicit_bzero(void* p, size_t n);
    int mlock(const(void)* p, size_t n);
    int munlock(const(void)* p, size_t n);
    void* calloc(size_t n, size_t size);
    void free(void* p);
}

private struct Secret
{
    ubyte* data;
    long len;
    bool live;
}

private __gshared Secret[] gSecrets;

private bool valid(long h) { return h >= 0 && h < gSecrets.length && gSecrets[cast(size_t) h].live; }

/// A zeroed, locked buffer of n bytes; its handle.
long secretNew(long n)
{
    size_t size = n > 1 ? cast(size_t) n : 1;
    auto p = cast(ubyte*) calloc(size, 1);
    mlock(p, size);
    gSecrets ~= Secret(p, n, true);
    return cast(long) gSecrets.length - 1;
}

long secretLen(long h)
{
    if (!valid(h)) return 0;
    return gSecrets[cast(size_t) h].len;
}

void secretSet(long h, long i, long v)
{
    if (!valid(h) || i < 0 || i >= gSecrets[cast(size_t) h].len) return;
    gSecrets[cast(size_t) h].data[cast(size_t) i] = cast(ubyte)(v & 255);
}

long secretGet(long h, long i)
{
    if (!valid(h) || i < 0 || i >= gSecrets[cast(size_t) h].len) return 0;
    return gSecrets[cast(size_t) h].data[cast(size_t) i];
}

/// Overwrite (unremovably), unlock, free. The handle is dead afterwards.
void secretWipe(long h)
{
    if (!valid(h)) return;
    auto s = &gSecrets[cast(size_t) h];
    size_t size = s.len > 1 ? cast(size_t) s.len : 1;
    explicit_bzero(s.data, size);
    munlock(s.data, size);
    free(s.data);
    s.live = false;
    s.len = 0;
}
