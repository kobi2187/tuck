// D impl module for std.compress — the twin of compress_shim.nim.
// DEFLATE/zlib/gzip are zlib's, Zstandard is libzstd's.
module compress_shim;

pragma(lib, "z");
pragma(lib, "zstd");

import core.stdc.config : c_ulong;

private struct ZStream
{
    ubyte* next_in;
    uint avail_in;
    c_ulong total_in;
    ubyte* next_out;
    uint avail_out;
    c_ulong total_out;
    const(char)* msg;
    void* state;
    void* zalloc;
    void* zfree;
    void* opaque;
    int data_type;
    c_ulong adler;
    c_ulong reserved;
}

private extern (C) nothrow @nogc
{
    int deflateInit2_(ZStream* s, int level, int meth, int bits, int mem, int strat,
                      const(char)* version_, int size);
    int deflate(ZStream* s, int flush);
    int deflateEnd(ZStream* s);
    int inflateInit2_(ZStream* s, int bits, const(char)* version_, int size);
    int inflate(ZStream* s, int flush);
    int inflateEnd(ZStream* s);
    const(char)* zlibVersion();
    size_t ZSTD_compress(void* dst, size_t cap, const(void)* src, size_t n, int level);
    size_t ZSTD_decompress(void* dst, size_t cap, const(void)* src, size_t n);
    size_t ZSTD_compressBound(size_t n);
    uint ZSTD_isError(size_t code);
    ulong ZSTD_getFrameContentSize(const(void)* src, size_t n);
}

private ubyte* at(ubyte[] s) { return s.length == 0 ? null : s.ptr; }

private int windowBits(long format) { return format == 0 ? -15 : (format == 1 ? 15 : 31); }

ubyte[] zCompress(long format, long level, ubyte[] data)
{
    ZStream s;
    if (deflateInit2_(&s, cast(int) level, 8, windowBits(format), 8, 0, zlibVersion(), cast(int) ZStream.sizeof) != 0)
        return [];
    auto outp = new ubyte[data.length + data.length / 1000 + 64];
    s.next_in = at(data);
    s.avail_in = cast(uint) data.length;
    s.next_out = outp.ptr;
    s.avail_out = cast(uint) outp.length;
    auto rc = deflate(&s, 4);
    auto produced = cast(size_t) s.total_out;
    deflateEnd(&s);
    if (rc != 1) return [];
    return outp[0 .. produced];
}

ubyte[] zUncompress(long format, ubyte[] data, long limit)
{
    ubyte[] fail() { return [cast(ubyte) 0]; }
    ZStream s;
    if (inflateInit2_(&s, windowBits(format), zlibVersion(), cast(int) ZStream.sizeof) != 0) return fail();
    s.next_in = at(data);
    s.avail_in = cast(uint) data.length;
    auto outp = new ubyte[(data.length * 4 > 256 ? data.length * 4 : 256) + 1];
    size_t total = 0;
    int rc = 0;
    while (true)
    {
        if (total + 1 >= outp.length)
        {
            if (outp.length > cast(size_t) limit + 1)
            {
                inflateEnd(&s);
                return fail();
            }
            outp.length = outp.length * 2;
        }
        s.next_out = &outp[1 + total];
        s.avail_out = cast(uint)(outp.length - 1 - total);
        rc = inflate(&s, 0);
        total = cast(size_t) s.total_out;
        if (rc == 1 || rc < 0 || (rc == 0 && s.avail_in == 0 && s.avail_out != 0)) break;
    }
    inflateEnd(&s);
    if (rc != 1 || total > cast(size_t) limit) return fail();
    outp[0] = 1;
    return outp[0 .. total + 1];
}

ubyte[] zstdCompress(long level, ubyte[] data)
{
    auto cap = ZSTD_compressBound(data.length);
    auto outp = new ubyte[cap + 1];
    auto n = ZSTD_compress(outp.ptr, cap, at(data), data.length, cast(int) level);
    if (ZSTD_isError(n) != 0) return [];
    return outp[0 .. n];
}

ubyte[] zstdDecompress(ubyte[] data, long limit)
{
    ubyte[] fail() { return [cast(ubyte) 0]; }
    auto size = ZSTD_getFrameContentSize(at(data), data.length);
    if (size >= int.max || cast(long) size > limit) return fail();
    auto outp = new ubyte[cast(size_t) size + 1];
    auto n = ZSTD_decompress(outp.ptr + 1, cast(size_t) size, at(data), data.length);
    if (ZSTD_isError(n) != 0 || n != cast(size_t) size) return fail();
    outp[0] = 1;
    return outp;
}
