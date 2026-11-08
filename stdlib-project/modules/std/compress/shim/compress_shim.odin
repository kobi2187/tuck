// Odin impl module for std.compress — the twin of compress_shim.nim.
// DEFLATE/zlib/gzip are zlib's, Zstandard is libzstd's.
package compress_shim

import "core:c"

foreign import z "system:z"
foreign import zstd "system:zstd"

@(private) ZStream :: struct {
	next_in:   [^]u8,
	avail_in:  c.uint,
	total_in:  c.ulong,
	next_out:  [^]u8,
	avail_out: c.uint,
	total_out: c.ulong,
	msg:       cstring,
	state:     rawptr,
	zalloc:    rawptr,
	zfree:     rawptr,
	opaque:    rawptr,
	data_type: c.int,
	adler:     c.ulong,
	reserved:  c.ulong,
}

@(default_calling_convention = "c", private)
foreign z {
	deflateInit2_ :: proc(s: ^ZStream, level, meth, bits, mem, strat: c.int, version: cstring, size: c.int) -> c.int ---
	deflate :: proc(s: ^ZStream, flush: c.int) -> c.int ---
	deflateEnd :: proc(s: ^ZStream) -> c.int ---
	inflateInit2_ :: proc(s: ^ZStream, bits: c.int, version: cstring, size: c.int) -> c.int ---
	inflate :: proc(s: ^ZStream, flush: c.int) -> c.int ---
	inflateEnd :: proc(s: ^ZStream) -> c.int ---
	zlibVersion :: proc() -> cstring ---
}

@(default_calling_convention = "c", private)
foreign zstd {
	ZSTD_compress :: proc(dst: rawptr, cap: c.size_t, src: rawptr, n: c.size_t, level: c.int) -> c.size_t ---
	ZSTD_decompress :: proc(dst: rawptr, cap: c.size_t, src: rawptr, n: c.size_t) -> c.size_t ---
	ZSTD_compressBound :: proc(n: c.size_t) -> c.size_t ---
	ZSTD_isError :: proc(code: c.size_t) -> c.uint ---
	ZSTD_getFrameContentSize :: proc(src: rawptr, n: c.size_t) -> c.ulonglong ---
}

@(private)
at :: proc(s: [dynamic]u8) -> [^]u8 {
	return len(s) == 0 ? nil : raw_data(s)
}

@(private)
windowBits :: proc(format: int) -> c.int {
	switch format {
	case 0: return -15
	case 1: return 15
	}
	return 31
}

zCompress :: proc(format: int, level: int, data: [dynamic]u8) -> [dynamic]u8 {
	s: ZStream
	if deflateInit2_(&s, c.int(level), 8, windowBits(format), 8, 0, zlibVersion(), c.int(size_of(ZStream))) != 0 {
		return make([dynamic]u8)
	}
	out := make([dynamic]u8, len(data) + len(data) / 1000 + 64)
	s.next_in = at(data)
	s.avail_in = c.uint(len(data))
	s.next_out = raw_data(out)
	s.avail_out = c.uint(len(out))
	rc := deflate(&s, 4)
	produced := int(s.total_out)
	deflateEnd(&s)
	if rc != 1 {
		delete(out)
		return make([dynamic]u8)
	}
	resize(&out, produced)
	return out
}

zUncompress :: proc(format: int, data: [dynamic]u8, limit: int) -> [dynamic]u8 {
	fail :: proc() -> [dynamic]u8 {
		o := make([dynamic]u8, 1)
		o[0] = 0
		return o
	}
	s: ZStream
	if inflateInit2_(&s, windowBits(format), zlibVersion(), c.int(size_of(ZStream))) != 0 do return fail()
	s.next_in = at(data)
	s.avail_in = c.uint(len(data))
	out := make([dynamic]u8, max(len(data) * 4, 256) + 1)
	total := 0
	rc: c.int = 0
	for {
		if total + 1 >= len(out) {
			if len(out) > limit + 1 {
				inflateEnd(&s)
				delete(out)
				return fail()
			}
			resize(&out, len(out) * 2)
		}
		s.next_out = &out[1 + total]
		s.avail_out = c.uint(len(out) - 1 - total)
		rc = inflate(&s, 0)
		total = int(s.total_out)
		if rc == 1 || rc < 0 || (rc == 0 && s.avail_in == 0 && s.avail_out != 0) do break
	}
	inflateEnd(&s)
	if rc != 1 || total > limit {
		delete(out)
		return fail()
	}
	out[0] = 1
	resize(&out, total + 1)
	return out
}

zstdCompress :: proc(level: int, data: [dynamic]u8) -> [dynamic]u8 {
	cap_ := ZSTD_compressBound(c.size_t(len(data)))
	out := make([dynamic]u8, int(cap_) + 1)
	n := ZSTD_compress(raw_data(out), cap_, at(data), c.size_t(len(data)), c.int(level))
	if ZSTD_isError(n) != 0 {
		delete(out)
		return make([dynamic]u8)
	}
	resize(&out, int(n))
	return out
}

zstdDecompress :: proc(data: [dynamic]u8, limit: int) -> [dynamic]u8 {
	fail :: proc() -> [dynamic]u8 {
		o := make([dynamic]u8, 1)
		o[0] = 0
		return o
	}
	size := ZSTD_getFrameContentSize(at(data), c.size_t(len(data)))
	if size >= c.ulonglong(max(i32)) || int(size) > limit do return fail()
	out := make([dynamic]u8, int(size) + 1)
	n := ZSTD_decompress(rawptr(uintptr(raw_data(out)) + 1), c.size_t(int(size)), at(data), c.size_t(len(data)))
	if ZSTD_isError(n) != 0 || int(n) != int(size) {
		delete(out)
		return fail()
	}
	out[0] = 1
	return out
}
