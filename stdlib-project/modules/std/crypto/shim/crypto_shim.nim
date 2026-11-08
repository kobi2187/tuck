# Nim impl module for std.crypto — twins: crypto_shim.odin and crypto_shim.d.
# The algorithms are libcrypto's (OpenSSL): vetted, constant-time where it
# matters, and not ours to get subtly wrong. Everything crosses as bytes in and
# bytes out; there is no key handle, so nothing here outlives a call.
#
# Digest kinds: 1 SHA-256, 2 SHA-512, 3 SHA3-256, 4 BLAKE2b-512, 5 SHA-1.
{.passL: "-lcrypto".}

proc EVP_sha256(): pointer {.importc, cdecl.}
proc EVP_sha512(): pointer {.importc, cdecl.}
proc EVP_sha3_256(): pointer {.importc, cdecl.}
proc EVP_blake2b512(): pointer {.importc, cdecl.}
proc EVP_sha1(): pointer {.importc, cdecl.}
proc EVP_Digest(data: pointer, n: csize_t, md: ptr uint8, size: ptr cuint, t, impl: pointer): cint {.importc, cdecl.}
proc HMAC(evp: pointer, key: pointer, keylen: cint, d: pointer, n: csize_t,
          md: ptr uint8, mdlen: ptr cuint): pointer {.importc, cdecl.}
proc PKCS5_PBKDF2_HMAC(pass: pointer, passlen: cint, salt: pointer, saltlen: cint,
                       iter: cint, digest: pointer, keylen: cint, outp: ptr uint8): cint {.importc, cdecl.}
proc RAND_bytes(buf: ptr uint8, n: cint): cint {.importc, cdecl.}
proc CRYPTO_memcmp(a, b: pointer, n: csize_t): cint {.importc, cdecl.}
proc EVP_chacha20_poly1305(): pointer {.importc, cdecl.}
proc EVP_CIPHER_CTX_new(): pointer {.importc, cdecl.}
proc EVP_CIPHER_CTX_free(c: pointer) {.importc, cdecl.}
proc EVP_CIPHER_CTX_ctrl(c: pointer, cmd, arg: cint, p: pointer): cint {.importc, cdecl.}
proc EVP_EncryptInit_ex(c, cipher, impl: pointer, key, iv: pointer): cint {.importc, cdecl.}
proc EVP_EncryptUpdate(c: pointer, outp: pointer, outl: ptr cint, inp: pointer, inl: cint): cint {.importc, cdecl.}
proc EVP_EncryptFinal_ex(c: pointer, outp: pointer, outl: ptr cint): cint {.importc, cdecl.}
proc EVP_DecryptInit_ex(c, cipher, impl: pointer, key, iv: pointer): cint {.importc, cdecl.}
proc EVP_DecryptUpdate(c: pointer, outp: pointer, outl: ptr cint, inp: pointer, inl: cint): cint {.importc, cdecl.}
proc EVP_DecryptFinal_ex(c: pointer, outp: pointer, outl: ptr cint): cint {.importc, cdecl.}

proc at(s: seq[uint8]): pointer =
  if s.len == 0: nil else: unsafeAddr s[0]

proc digestOf(kind: int): pointer =
  case kind
  of 1: EVP_sha256()
  of 2: EVP_sha512()
  of 3: EVP_sha3_256()
  of 4: EVP_blake2b512()
  of 5: EVP_sha1()
  else: nil

proc cryptoHash*(kind: int, data: seq[uint8]): seq[uint8] =
  ## The digest, or empty for an unknown kind.
  let d = digestOf(kind)
  if d == nil: return @[]
  var md = newSeq[uint8](64)
  var n: cuint
  if EVP_Digest(at(data), csize_t(data.len), addr md[0], addr n, d, nil) != 1: return @[]
  md.setLen int(n)
  md

proc cryptoHmac*(kind: int, key, data: seq[uint8]): seq[uint8] =
  let d = digestOf(kind)
  if d == nil: return @[]
  var md = newSeq[uint8](64)
  var n: cuint
  if HMAC(d, at(key), cint(key.len), at(data), csize_t(data.len), addr md[0], addr n) == nil: return @[]
  md.setLen int(n)
  md

proc cryptoPbkdf2*(kind: int, pass, salt: seq[uint8], iterations, outLen: int): seq[uint8] =
  let d = digestOf(kind)
  if d == nil or outLen <= 0 or iterations <= 0: return @[]
  var key = newSeq[uint8](outLen)
  if PKCS5_PBKDF2_HMAC(at(pass), cint(pass.len), at(salt), cint(salt.len),
                       cint(iterations), d, cint(outLen), addr key[0]) != 1: return @[]
  key

proc cryptoRandom*(n: int): seq[uint8] =
  if n <= 0: return @[]
  var buf = newSeq[uint8](n)
  if RAND_bytes(addr buf[0], cint(n)) != 1: return @[]
  buf

proc cryptoSame*(a, b: seq[uint8]): bool =
  if a.len != b.len: return false
  if a.len == 0: return true
  CRYPTO_memcmp(at(a), at(b), csize_t(a.len)) == 0

proc cryptoSeal*(key, nonce, aad, plain: seq[uint8]): seq[uint8] =
  ## ChaCha20-Poly1305 (32-byte key, 12-byte nonce): ciphertext followed by the
  ## 16-byte tag. Empty on a bad key or nonce size.
  if key.len != 32 or nonce.len != 12: return @[]
  let ctx = EVP_CIPHER_CTX_new()
  defer: EVP_CIPHER_CTX_free(ctx)
  if EVP_EncryptInit_ex(ctx, EVP_chacha20_poly1305(), nil, at(key), at(nonce)) != 1: return @[]
  var n: cint
  if aad.len > 0 and EVP_EncryptUpdate(ctx, nil, addr n, at(aad), cint(aad.len)) != 1: return @[]
  var outp = newSeq[uint8](plain.len + 16)
  var total = 0
  if plain.len > 0:
    if EVP_EncryptUpdate(ctx, addr outp[0], addr n, at(plain), cint(plain.len)) != 1: return @[]
    total = int n
  var fin: array[16, uint8]
  if EVP_EncryptFinal_ex(ctx, addr fin[0], addr n) != 1: return @[]
  if EVP_CIPHER_CTX_ctrl(ctx, 0x10, 16, addr outp[total]) != 1: return @[]
  outp.setLen total + 16
  outp

proc cryptoOpen*(key, nonce, aad, sealed: seq[uint8]): seq[uint8] =
  ## [1] ++ plaintext when the tag verifies; [0] when it does not (or the sizes are wrong).
  if key.len != 32 or nonce.len != 12 or sealed.len < 16: return @[0'u8]
  let ctx = EVP_CIPHER_CTX_new()
  defer: EVP_CIPHER_CTX_free(ctx)
  let clen = sealed.len - 16
  var tag: array[16, uint8]
  for i in 0 ..< 16: tag[i] = sealed[clen + i]
  if EVP_DecryptInit_ex(ctx, EVP_chacha20_poly1305(), nil, at(key), at(nonce)) != 1: return @[0'u8]
  var n: cint
  if aad.len > 0 and EVP_DecryptUpdate(ctx, nil, addr n, at(aad), cint(aad.len)) != 1: return @[0'u8]
  var plain = newSeq[uint8](clen + 1)
  var total = 0
  if clen > 0:
    if EVP_DecryptUpdate(ctx, addr plain[1], addr n, at(sealed), cint(clen)) != 1: return @[0'u8]
    total = int n
  if EVP_CIPHER_CTX_ctrl(ctx, 0x11, 16, addr tag[0]) != 1: return @[0'u8]
  var fin: array[16, uint8]
  if EVP_DecryptFinal_ex(ctx, addr fin[0], addr n) != 1: return @[0'u8]
  plain[0] = 1
  plain.setLen total + 1
  plain
