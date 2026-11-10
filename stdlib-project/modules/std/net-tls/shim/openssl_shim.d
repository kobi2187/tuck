// D impl module for std.net-tls' OpenSSL driver — the twin of openssl_shim.nim.
// X509 and SSL pointers stay in these tables; Tuck holds handles.
module openssl_shim;

import std.socket : TcpSocket, InternetAddress, Socket;

pragma(lib, "ssl");
pragma(lib, "crypto");

private extern (C) nothrow @nogc
{
    void* BIO_new_mem_buf(const(void)* buf, int len);
    int BIO_free(void* b);
    void* PEM_read_bio_X509(void* bio, void* x, void* cb, void* u);
    void* X509_get_subject_name(void* x);
    void* X509_get_issuer_name(void* x);
    int X509_NAME_get_text_by_NID(void* n, int nid, char* buf, int len);
    void* X509_getm_notBefore(void* x);
    void* X509_getm_notAfter(void* x);
    void* ASN1_TIME_set(void* s, long t);
    int ASN1_TIME_diff(int* pday, int* psec, void* from, void* to);
    void* TLS_client_method();
    void* SSL_CTX_new(void* m);
    int SSL_CTX_set_default_verify_paths(void* c);
    void SSL_CTX_set_verify(void* c, int mode, void* cb);
    void* SSL_new(void* c);
    int SSL_set_fd(void* s, int fd);
    long SSL_ctrl(void* s, int cmd, long larg, void* parg);
    int SSL_connect(void* s);
    int SSL_read(void* s, void* buf, int n);
    int SSL_write(void* s, const(void)* buf, int n);
    int SSL_shutdown(void* s);
    void SSL_free(void* s);
    void SSL_CTX_free(void* c);
    void* SSL_get_peer_cert_chain(void* s);
    long SSL_get_verify_result(void* s);
    int OPENSSL_sk_num(void* st);
    void* OPENSSL_sk_value(void* st, int i);
}

private struct Conn
{
    void* ssl;
    void* ctx;
    TcpSocket sock;
    bool live;
}

private __gshared void*[] gCerts;
private __gshared Conn[] gConns;

private bool certValid(long h) { return h >= 0 && h < gCerts.length && gCerts[cast(size_t) h] !is null; }

/// A certificate handle >= 0, or -1 when the text is not a PEM certificate.
long certFromPem(string pem)
{
    auto bio = BIO_new_mem_buf(pem.ptr, cast(int) pem.length);
    if (bio is null) return -1;
    auto x = PEM_read_bio_X509(bio, null, null, null);
    BIO_free(bio);
    if (x is null) return -1;
    gCerts ~= x;
    return cast(long) gCerts.length - 1;
}

private ubyte[] nameText(void* n)
{
    char[256] buf;
    auto k = X509_NAME_get_text_by_NID(n, 13, buf.ptr, 256);
    ubyte[] out_;
    foreach (i; 0 .. (k > 0 ? k : 0)) out_ ~= cast(ubyte) buf[i];
    return out_;
}

ubyte[] certSubject(long h)
{
    if (!certValid(h)) return [];
    return nameText(X509_get_subject_name(gCerts[cast(size_t) h]));
}

ubyte[] certIssuer(long h)
{
    if (!certValid(h)) return [];
    return nameText(X509_get_issuer_name(gCerts[cast(size_t) h]));
}

private long sinceEpochMs(void* t)
{
    auto epoch = ASN1_TIME_set(null, 0);
    int days, secs;
    if (ASN1_TIME_diff(&days, &secs, epoch, t) != 1) return 0;
    return cast(long) days * 86_400_000L + cast(long) secs * 1000L;
}

long certNotBeforeMs(long h)
{
    if (!certValid(h)) return 0;
    return sinceEpochMs(X509_getm_notBefore(gCerts[cast(size_t) h]));
}

long certNotAfterMs(long h)
{
    if (!certValid(h)) return 0;
    return sinceEpochMs(X509_getm_notAfter(gCerts[cast(size_t) h]));
}

private bool connValid(long c) { return c >= 0 && c < gConns.length && gConns[cast(size_t) c].live; }

/// A connection handle >= 0; -1 no TCP, -2 handshake refused, -3 verification
/// failed (only when `verify` is 1).
long tlsConnect(string host, long port, long verify)
{
    TcpSocket sock;
    try
    {
        sock = new TcpSocket();
        sock.connect(new InternetAddress(host, cast(ushort) port));
    }
    catch (Exception)
    {
        return -1;
    }
    auto ctx = SSL_CTX_new(TLS_client_method());
    if (ctx is null) return -2;
    SSL_CTX_set_default_verify_paths(ctx);
    SSL_CTX_set_verify(ctx, verify == 1 ? 1 : 0, null);
    auto s = SSL_new(ctx);
    SSL_set_fd(s, cast(int) sock.handle);
    auto chost = (host ~ "\0").ptr;
    SSL_ctrl(s, 55, 0, cast(void*) chost);
    if (SSL_connect(s) != 1)
    {
        bool bad = verify == 1 && SSL_get_verify_result(s) != 0;
        SSL_free(s);
        SSL_CTX_free(ctx);
        sock.close();
        return bad ? -3 : -2;
    }
    gConns ~= Conn(s, ctx, sock, true);
    return cast(long) gConns.length - 1;
}

long tlsChainLen(long c)
{
    if (!connValid(c)) return 0;
    auto st = SSL_get_peer_cert_chain(gConns[cast(size_t) c].ssl);
    if (st is null) return 0;
    return OPENSSL_sk_num(st);
}

/// A certificate handle for the i-th certificate the peer sent (leaf first), or -1.
long tlsChainCert(long c, long i)
{
    if (!connValid(c)) return -1;
    auto st = SSL_get_peer_cert_chain(gConns[cast(size_t) c].ssl);
    if (st is null || i < 0 || i >= OPENSSL_sk_num(st)) return -1;
    gCerts ~= OPENSSL_sk_value(st, cast(int) i);
    return cast(long) gCerts.length - 1;
}

long tlsSend(long c, string data)
{
    if (!connValid(c) || data.length == 0) return 0;
    return SSL_write(gConns[cast(size_t) c].ssl, data.ptr, cast(int) data.length);
}

ubyte[] tlsRecv(long c, long max)
{
    if (!connValid(c) || max <= 0) return [];
    auto buf = new ubyte[cast(size_t) max];
    auto n = SSL_read(gConns[cast(size_t) c].ssl, buf.ptr, cast(int) max);
    if (n <= 0) return [];
    return buf[0 .. n];
}

void tlsClose(long c)
{
    if (!connValid(c)) return;
    auto cn = &gConns[cast(size_t) c];
    SSL_shutdown(cn.ssl);
    SSL_free(cn.ssl);
    SSL_CTX_free(cn.ctx);
    cn.sock.close();
    cn.live = false;
}
