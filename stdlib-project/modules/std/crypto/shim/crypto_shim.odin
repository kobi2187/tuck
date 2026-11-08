// Odin impl module for std.crypto — the twin of crypto_shim.nim.
// libcrypto's algorithms; bytes in, bytes out, nothing outlives a call.
package crypto_shim

import "core:c"

foreign import crypto "system:crypto"

@(default_calling_convention = "c", private)
foreign crypto {
	EVP_sha256 :: proc() -> rawptr ---
	EVP_sha512 :: proc() -> rawptr ---
	EVP_sha3_256 :: proc() -> rawptr ---
	EVP_blake2b512 :: proc() -> rawptr ---
	EVP_sha1 :: proc() -> rawptr ---
	EVP_Digest :: proc(data: rawptr, n: c.size_t, md: [^]u8, size: ^c.uint, t, impl: rawptr) -> c.int ---
	HMAC :: proc(evp: rawptr, key: rawptr, keylen: c.int, d: rawptr, n: c.size_t, md: [^]u8, mdlen: ^c.uint) -> rawptr ---
	PKCS5_PBKDF2_HMAC :: proc(pass: rawptr, passlen: c.int, salt: rawptr, saltlen: c.int, iter: c.int, digest: rawptr, keylen: c.int, out: [^]u8) -> c.int ---
	RAND_bytes :: proc(buf: [^]u8, n: c.int) -> c.int ---
	CRYPTO_memcmp :: proc(a, b: rawptr, n: c.size_t) -> c.int ---
	EVP_chacha20_poly1305 :: proc() -> rawptr ---
	EVP_CIPHER_CTX_new :: proc() -> rawptr ---
	EVP_CIPHER_CTX_free :: proc(ctx: rawptr) ---
	EVP_CIPHER_CTX_ctrl :: proc(ctx: rawptr, cmd, arg: c.int, p: rawptr) -> c.int ---
	EVP_EncryptInit_ex :: proc(ctx, cipher, impl: rawptr, key, iv: rawptr) -> c.int ---
	EVP_EncryptUpdate :: proc(ctx: rawptr, out: rawptr, outl: ^c.int, inp: rawptr, inl: c.int) -> c.int ---
	EVP_EncryptFinal_ex :: proc(ctx: rawptr, out: rawptr, outl: ^c.int) -> c.int ---
	EVP_DecryptInit_ex :: proc(ctx, cipher, impl: rawptr, key, iv: rawptr) -> c.int ---
	EVP_DecryptUpdate :: proc(ctx: rawptr, out: rawptr, outl: ^c.int, inp: rawptr, inl: c.int) -> c.int ---
	EVP_DecryptFinal_ex :: proc(ctx: rawptr, out: rawptr, outl: ^c.int) -> c.int ---
}

@(private)
at :: proc(s: [dynamic]u8) -> rawptr {
	return len(s) == 0 ? nil : rawptr(&s[0])
}

@(private)
digestOf :: proc(kind: int) -> rawptr {
	switch kind {
	case 1: return EVP_sha256()
	case 2: return EVP_sha512()
	case 3: return EVP_sha3_256()
	case 4: return EVP_blake2b512()
	case 5: return EVP_sha1()
	}
	return nil
}

@(private)
bytes :: proc(n: int) -> [dynamic]u8 {
	out := make([dynamic]u8, n)
	return out
}

// The digest, or empty for an unknown kind.
cryptoHash :: proc(kind: int, data: [dynamic]u8) -> [dynamic]u8 {
	d := digestOf(kind)
	if d == nil do return make([dynamic]u8)
	md := bytes(64)
	n: c.uint
	if EVP_Digest(at(data), c.size_t(len(data)), raw_data(md), &n, d, nil) != 1 {
		delete(md)
		return make([dynamic]u8)
	}
	resize(&md, int(n))
	return md
}

cryptoHmac :: proc(kind: int, key: [dynamic]u8, data: [dynamic]u8) -> [dynamic]u8 {
	d := digestOf(kind)
	if d == nil do return make([dynamic]u8)
	md := bytes(64)
	n: c.uint
	if HMAC(d, at(key), c.int(len(key)), at(data), c.size_t(len(data)), raw_data(md), &n) == nil {
		delete(md)
		return make([dynamic]u8)
	}
	resize(&md, int(n))
	return md
}

cryptoPbkdf2 :: proc(kind: int, pass: [dynamic]u8, salt: [dynamic]u8, iterations: int, outLen: int) -> [dynamic]u8 {
	d := digestOf(kind)
	if d == nil || outLen <= 0 || iterations <= 0 do return make([dynamic]u8)
	key := bytes(outLen)
	if PKCS5_PBKDF2_HMAC(at(pass), c.int(len(pass)), at(salt), c.int(len(salt)), c.int(iterations), d, c.int(outLen), raw_data(key)) != 1 {
		delete(key)
		return make([dynamic]u8)
	}
	return key
}

cryptoRandom :: proc(n: int) -> [dynamic]u8 {
	if n <= 0 do return make([dynamic]u8)
	buf := bytes(n)
	if RAND_bytes(raw_data(buf), c.int(n)) != 1 {
		delete(buf)
		return make([dynamic]u8)
	}
	return buf
}

cryptoSame :: proc(a: [dynamic]u8, b: [dynamic]u8) -> bool {
	if len(a) != len(b) do return false
	if len(a) == 0 do return true
	return CRYPTO_memcmp(at(a), at(b), c.size_t(len(a))) == 0
}

// ChaCha20-Poly1305 (32-byte key, 12-byte nonce): ciphertext then the 16-byte
// tag. Empty on a bad key or nonce size.
cryptoSeal :: proc(key: [dynamic]u8, nonce: [dynamic]u8, aad: [dynamic]u8, plain: [dynamic]u8) -> [dynamic]u8 {
	if len(key) != 32 || len(nonce) != 12 do return make([dynamic]u8)
	ctx := EVP_CIPHER_CTX_new()
	defer EVP_CIPHER_CTX_free(ctx)
	if EVP_EncryptInit_ex(ctx, EVP_chacha20_poly1305(), nil, at(key), at(nonce)) != 1 do return make([dynamic]u8)
	n: c.int
	if len(aad) > 0 && EVP_EncryptUpdate(ctx, nil, &n, at(aad), c.int(len(aad))) != 1 do return make([dynamic]u8)
	out := bytes(len(plain) + 16)
	total := 0
	if len(plain) > 0 {
		if EVP_EncryptUpdate(ctx, raw_data(out), &n, at(plain), c.int(len(plain))) != 1 {
			delete(out)
			return make([dynamic]u8)
		}
		total = int(n)
	}
	fin: [16]u8
	if EVP_EncryptFinal_ex(ctx, &fin[0], &n) != 1 {
		delete(out)
		return make([dynamic]u8)
	}
	if EVP_CIPHER_CTX_ctrl(ctx, 0x10, 16, rawptr(&out[total])) != 1 {
		delete(out)
		return make([dynamic]u8)
	}
	resize(&out, total + 16)
	return out
}

// [1] ++ plaintext when the tag verifies; [0] when it does not.
cryptoOpen :: proc(key: [dynamic]u8, nonce: [dynamic]u8, aad: [dynamic]u8, sealed: [dynamic]u8) -> [dynamic]u8 {
	fail :: proc() -> [dynamic]u8 {
		out := make([dynamic]u8, 1)
		out[0] = 0
		return out
	}
	if len(key) != 32 || len(nonce) != 12 || len(sealed) < 16 do return fail()
	ctx := EVP_CIPHER_CTX_new()
	defer EVP_CIPHER_CTX_free(ctx)
	clen := len(sealed) - 16
	tag: [16]u8
	for i in 0 ..< 16 do tag[i] = sealed[clen + i]
	if EVP_DecryptInit_ex(ctx, EVP_chacha20_poly1305(), nil, at(key), at(nonce)) != 1 do return fail()
	n: c.int
	if len(aad) > 0 && EVP_DecryptUpdate(ctx, nil, &n, at(aad), c.int(len(aad))) != 1 do return fail()
	plain := bytes(clen + 1)
	total := 0
	if clen > 0 {
		if EVP_DecryptUpdate(ctx, rawptr(&plain[1]), &n, at(sealed), c.int(clen)) != 1 {
			delete(plain)
			return fail()
		}
		total = int(n)
	}
	if EVP_CIPHER_CTX_ctrl(ctx, 0x11, 16, &tag[0]) != 1 {
		delete(plain)
		return fail()
	}
	fin: [16]u8
	if EVP_DecryptFinal_ex(ctx, &fin[0], &n) != 1 {
		delete(plain)
		return fail()
	}
	plain[0] = 1
	resize(&plain, total + 1)
	return plain
}
