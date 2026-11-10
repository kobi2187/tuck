# Nim impl module for std.compress — twins: compress_shim.odin and
# compress_shim.d. DEFLATE/zlib/gzip are zlib's, Zstandard is libzstd's: the
# vetted implementations, bytes in and bytes out.
#
# formats: 0 raw deflate, 1 zlib, 2 gzip.  A decode answers [1] ++ data on
# success and [0] on a corrupt stream or when the result would pass `limit`.
{.passL: "-lz -lzstd".}

type ZStream {.importc: "z_stream", header: "<zlib.h>".} = object
  next_in: ptr uint8
  avail_in: cuint
  total_in: culong
  next_out: ptr uint8
  avail_out: cuint
  total_out: culong
  msg: cstring
  state: pointer
  zalloc, zfree, opaque: pointer
  data_type: cint
  adler, reserved: culong

proc deflateInit2x(s: ptr ZStream, level, meth, bits, mem, strat: cint,
                   version: cstring, size: cint): cint {.importc: "deflateInit2_", header: "<zlib.h>", cdecl.}
proc deflate(s: ptr ZStream, flush: cint): cint {.importc, header: "<zlib.h>", cdecl.}
proc deflateEnd(s: ptr ZStream): cint {.importc, header: "<zlib.h>", cdecl.}
proc inflateInit2x(s: ptr ZStream, bits: cint, version: cstring, size: cint): cint {.importc: "inflateInit2_", header: "<zlib.h>", cdecl.}
proc inflate(s: ptr ZStream, flush: cint): cint {.importc, header: "<zlib.h>", cdecl.}
proc inflateEnd(s: ptr ZStream): cint {.importc, header: "<zlib.h>", cdecl.}
proc zlibVersion(): cstring {.importc, header: "<zlib.h>", cdecl.}
proc ZSTD_compress(dst: pointer, cap: csize_t, src: pointer, n: csize_t, level: cint): csize_t {.importc, header: "<zstd.h>", cdecl.}
proc ZSTD_decompress(dst: pointer, cap: csize_t, src: pointer, n: csize_t): csize_t {.importc, header: "<zstd.h>", cdecl.}
proc ZSTD_compressBound(n: csize_t): csize_t {.importc, header: "<zstd.h>", cdecl.}
proc ZSTD_isError(code: csize_t): cuint {.importc, header: "<zstd.h>", cdecl.}
proc ZSTD_getFrameContentSize(src: pointer, n: csize_t): culonglong {.importc, header: "<zstd.h>", cdecl.}

proc at(s: seq[uint8]): ptr uint8 =
  if s.len == 0: nil else: unsafeAddr s[0]

proc windowBits(format: int): cint =
  case format
  of 0: -15
  of 1: 15
  else: 31

proc zCompress*(format, level: int, data: seq[uint8]): seq[uint8] =
  var s: ZStream
  if deflateInit2x(addr s, cint level, 8, windowBits(format), 8, 0, zlibVersion(), cint sizeof(ZStream)) != 0:
    return @[]
  var outp = newSeq[uint8](data.len + data.len div 1000 + 64)
  s.next_in = at(data)
  s.avail_in = cuint data.len
  s.next_out = addr outp[0]
  s.avail_out = cuint outp.len
  let rc = deflate(addr s, 4)   # Z_FINISH
  let produced = int s.total_out
  discard deflateEnd(addr s)
  if rc != 1: return @[]        # Z_STREAM_END
  outp.setLen produced
  outp

proc zUncompress*(format: int, data: seq[uint8], limit: int): seq[uint8] =
  var s: ZStream
  if inflateInit2x(addr s, windowBits(format), zlibVersion(), cint sizeof(ZStream)) != 0:
    return @[0'u8]
  s.next_in = at(data)
  s.avail_in = cuint data.len
  var outp = newSeq[uint8](max(data.len * 4, 256) + 1)
  var total = 0
  var rc: cint = 0
  while true:
    if total + 1 >= outp.len:
      if outp.len > limit + 1:
        discard inflateEnd(addr s)
        return @[0'u8]
      outp.setLen outp.len * 2
    s.next_out = addr outp[1 + total]
    s.avail_out = cuint(outp.len - 1 - total)
    rc = inflate(addr s, 0)
    total = int s.total_out
    if rc == 1 or rc < 0 or (rc == 0 and s.avail_in == 0 and s.avail_out != 0): break
  discard inflateEnd(addr s)
  if rc != 1 or total > limit: return @[0'u8]
  outp[0] = 1
  outp.setLen total + 1
  outp

proc zstdCompress*(level: int, data: seq[uint8]): seq[uint8] =
  let cap = ZSTD_compressBound(csize_t data.len)
  var outp = newSeq[uint8](int cap + 1)
  let n = ZSTD_compress(addr outp[0], cap, at(data), csize_t data.len, cint level)
  if ZSTD_isError(n) != 0: return @[]
  outp.setLen int n
  outp

proc zstdDecompress*(data: seq[uint8], limit: int): seq[uint8] =
  let size = ZSTD_getFrameContentSize(at(data), csize_t data.len)
  if size >= culonglong(high(int32)) or int(size) > limit: return @[0'u8]
  var outp = newSeq[uint8](int(size) + 1)
  let n = ZSTD_decompress(cast[pointer](cast[int](addr outp[0]) + 1), csize_t int(size), at(data), csize_t data.len)
  if ZSTD_isError(n) != 0 or int(n) != int(size): return @[0'u8]
  outp[0] = 1
  outp
