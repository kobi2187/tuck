// D impl module for std.crypto — the twin of crypto_shim.nim.
// libcrypto's algorithms; bytes in, bytes out, nothing outlives a call.
module crypto_shim;

pragma(lib, "crypto");

private extern (C) nothrow @nogc
{
    void* EVP_sha256();
    void* EVP_sha512();
    void* EVP_sha3_256();
    void* EVP_blake2b512();
    void* EVP_sha1();
    int EVP_Digest(const(void)* data, size_t n, ubyte* md, uint* size, const(void)* t, void* impl);
    void* HMAC(const(void)* evp, const(void)* key, int keylen, const(void)* d, size_t n,
               ubyte* md, uint* mdlen);
    int PKCS5_PBKDF2_HMAC(const(void)* pass, int passlen, const(void)* salt, int saltlen,
                          int iter, const(void)* digest, int keylen, ubyte* out_);
    int RAND_bytes(ubyte* buf, int n);
    int CRYPTO_memcmp(const(void)* a, const(void)* b, size_t n);
    void* EVP_chacha20_poly1305();
    void* EVP_CIPHER_CTX_new();
    void EVP_CIPHER_CTX_free(void* c);
    int EVP_CIPHER_CTX_ctrl(void* c, int cmd, int arg, void* p);
    int EVP_EncryptInit_ex(void* c, const(void)* cipher, void* impl, const(void)* key, const(void)* iv);
    int EVP_EncryptUpdate(void* c, void* out_, int* outl, const(void)* inp, int inl);
    int EVP_EncryptFinal_ex(void* c, void* out_, int* outl);
    int EVP_DecryptInit_ex(void* c, const(void)* cipher, void* impl, const(void)* key, const(void)* iv);
    int EVP_DecryptUpdate(void* c, void* out_, int* outl, const(void)* inp, int inl);
    int EVP_DecryptFinal_ex(void* c, void* out_, int* outl);
}

private const(void)* at(const(ubyte)[] s) { return s.length == 0 ? null : s.ptr; }

private void* digestOf(long kind)
{
    switch (kind)
    {
        case 1: return EVP_sha256();
        case 2: return EVP_sha512();
        case 3: return EVP_sha3_256();
        case 4: return EVP_blake2b512();
        case 5: return EVP_sha1();
        default: return null;
    }
}

/// The digest, or empty for an unknown kind.
ubyte[] cryptoHash(long kind, ubyte[] data)
{
    auto d = digestOf(kind);
    if (d is null) return [];
    auto md = new ubyte[64];
    uint n;
    if (EVP_Digest(at(data), data.length, md.ptr, &n, d, null) != 1) return [];
    return md[0 .. n];
}

ubyte[] cryptoHmac(long kind, ubyte[] key, ubyte[] data)
{
    auto d = digestOf(kind);
    if (d is null) return [];
    auto md = new ubyte[64];
    uint n;
    if (HMAC(d, at(key), cast(int) key.length, at(data), data.length, md.ptr, &n) is null) return [];
    return md[0 .. n];
}

ubyte[] cryptoPbkdf2(long kind, ubyte[] pass, ubyte[] salt, long iterations, long outLen)
{
    auto d = digestOf(kind);
    if (d is null || outLen <= 0 || iterations <= 0) return [];
    auto key = new ubyte[cast(size_t) outLen];
    if (PKCS5_PBKDF2_HMAC(at(pass), cast(int) pass.length, at(salt), cast(int) salt.length,
                          cast(int) iterations, d, cast(int) outLen, key.ptr) != 1) return [];
    return key;
}

ubyte[] cryptoRandom(long n)
{
    if (n <= 0) return [];
    auto buf = new ubyte[cast(size_t) n];
    if (RAND_bytes(buf.ptr, cast(int) n) != 1) return [];
    return buf;
}

bool cryptoSame(ubyte[] a, ubyte[] b)
{
    if (a.length != b.length) return false;
    if (a.length == 0) return true;
    return CRYPTO_memcmp(at(a), at(b), a.length) == 0;
}

/// ChaCha20-Poly1305 (32-byte key, 12-byte nonce): ciphertext then the 16-byte
/// tag. Empty on a bad key or nonce size.
ubyte[] cryptoSeal(ubyte[] key, ubyte[] nonce, ubyte[] aad, ubyte[] plain)
{
    if (key.length != 32 || nonce.length != 12) return [];
    auto ctx = EVP_CIPHER_CTX_new();
    scope (exit) EVP_CIPHER_CTX_free(ctx);
    if (EVP_EncryptInit_ex(ctx, EVP_chacha20_poly1305(), null, at(key), at(nonce)) != 1) return [];
    int n;
    if (aad.length > 0 && EVP_EncryptUpdate(ctx, null, &n, at(aad), cast(int) aad.length) != 1) return [];
    auto outp = new ubyte[plain.length + 16];
    size_t total = 0;
    if (plain.length > 0)
    {
        if (EVP_EncryptUpdate(ctx, outp.ptr, &n, at(plain), cast(int) plain.length) != 1) return [];
        total = n;
    }
    ubyte[16] fin;
    if (EVP_EncryptFinal_ex(ctx, fin.ptr, &n) != 1) return [];
    if (EVP_CIPHER_CTX_ctrl(ctx, 0x10, 16, &outp[total]) != 1) return [];
    return outp[0 .. total + 16];
}

/// [1] ~ plaintext when the tag verifies; [0] when it does not.
ubyte[] cryptoOpen(ubyte[] key, ubyte[] nonce, ubyte[] aad, ubyte[] sealed)
{
    ubyte[] fail() { return [cast(ubyte) 0]; }
    if (key.length != 32 || nonce.length != 12 || sealed.length < 16) return fail();
    auto ctx = EVP_CIPHER_CTX_new();
    scope (exit) EVP_CIPHER_CTX_free(ctx);
    auto clen = sealed.length - 16;
    ubyte[16] tag;
    foreach (i; 0 .. 16) tag[i] = sealed[clen + i];
    if (EVP_DecryptInit_ex(ctx, EVP_chacha20_poly1305(), null, at(key), at(nonce)) != 1) return fail();
    int n;
    if (aad.length > 0 && EVP_DecryptUpdate(ctx, null, &n, at(aad), cast(int) aad.length) != 1) return fail();
    auto plain = new ubyte[clen + 1];
    size_t total = 0;
    if (clen > 0)
    {
        if (EVP_DecryptUpdate(ctx, &plain[1], &n, at(sealed), cast(int) clen) != 1) return fail();
        total = n;
    }
    if (EVP_CIPHER_CTX_ctrl(ctx, 0x11, 16, tag.ptr) != 1) return fail();
    ubyte[16] fin;
    if (EVP_DecryptFinal_ex(ctx, fin.ptr, &n) != 1) return fail();
    plain[0] = 1;
    return plain[0 .. total + 1];
}
