// Odin impl module for std.net-tls' OpenSSL driver — the twin of openssl_shim.nim.
// X509 and SSL pointers stay in these tables; Tuck holds handles.
package openssl_shim

import "core:c"
import "core:net"
import "core:strings"

foreign import ssl "system:ssl"
foreign import crypto "system:crypto"

@(default_calling_convention = "c", private)
foreign crypto {
	BIO_new_mem_buf :: proc(buf: rawptr, len: c.int) -> rawptr ---
	BIO_free :: proc(b: rawptr) -> c.int ---
	PEM_read_bio_X509 :: proc(bio, x, cb, u: rawptr) -> rawptr ---
	X509_get_subject_name :: proc(x: rawptr) -> rawptr ---
	X509_get_issuer_name :: proc(x: rawptr) -> rawptr ---
	X509_NAME_get_text_by_NID :: proc(n: rawptr, nid: c.int, buf: [^]u8, len: c.int) -> c.int ---
	X509_getm_notBefore :: proc(x: rawptr) -> rawptr ---
	X509_getm_notAfter :: proc(x: rawptr) -> rawptr ---
	ASN1_TIME_set :: proc(s: rawptr, t: c.long) -> rawptr ---
	ASN1_TIME_diff :: proc(pday, psec: ^c.int, from, to: rawptr) -> c.int ---
	OPENSSL_sk_num :: proc(st: rawptr) -> c.int ---
	OPENSSL_sk_value :: proc(st: rawptr, i: c.int) -> rawptr ---
}

@(default_calling_convention = "c", private)
foreign ssl {
	TLS_client_method :: proc() -> rawptr ---
	SSL_CTX_new :: proc(m: rawptr) -> rawptr ---
	SSL_CTX_set_default_verify_paths :: proc(cx: rawptr) -> c.int ---
	SSL_CTX_set_verify :: proc(cx: rawptr, mode: c.int, cb: rawptr) ---
	SSL_new :: proc(cx: rawptr) -> rawptr ---
	SSL_set_fd :: proc(s: rawptr, fd: c.int) -> c.int ---
	SSL_ctrl :: proc(s: rawptr, cmd: c.int, larg: c.long, parg: rawptr) -> c.long ---
	SSL_connect :: proc(s: rawptr) -> c.int ---
	SSL_read :: proc(s: rawptr, buf: rawptr, n: c.int) -> c.int ---
	SSL_write :: proc(s: rawptr, buf: rawptr, n: c.int) -> c.int ---
	SSL_shutdown :: proc(s: rawptr) -> c.int ---
	SSL_free :: proc(s: rawptr) ---
	SSL_CTX_free :: proc(cx: rawptr) ---
	SSL_get_peer_cert_chain :: proc(s: rawptr) -> rawptr ---
	SSL_get_verify_result :: proc(s: rawptr) -> c.long ---
}

@(private) Conn :: struct {
	ssl, ctx: rawptr,
	sock:     net.TCP_Socket,
	live:     bool,
}

@(private) gCerts: [dynamic]rawptr
@(private) gConns: [dynamic]Conn

@(private)
certValid :: proc(h: int) -> bool { return h >= 0 && h < len(gCerts) && gCerts[h] != nil }

// A certificate handle >= 0, or -1 when the text is not a PEM certificate.
certFromPem :: proc(pem: string) -> int {
	cpem := strings.clone_to_cstring(pem, context.temp_allocator)
	bio := BIO_new_mem_buf(rawptr(cpem), c.int(len(pem)))
	if bio == nil do return -1
	x := PEM_read_bio_X509(bio, nil, nil, nil)
	BIO_free(bio)
	if x == nil do return -1
	append(&gCerts, x)
	return len(gCerts) - 1
}

@(private)
nameText :: proc(n: rawptr) -> [dynamic]u8 {
	out := make([dynamic]u8)
	buf: [256]u8
	k := int(X509_NAME_get_text_by_NID(n, 13, &buf[0], 256))
	for i in 0 ..< max(k, 0) do append(&out, buf[i])
	return out
}

certSubject :: proc(h: int) -> [dynamic]u8 {
	if !certValid(h) do return make([dynamic]u8)
	return nameText(X509_get_subject_name(gCerts[h]))
}

certIssuer :: proc(h: int) -> [dynamic]u8 {
	if !certValid(h) do return make([dynamic]u8)
	return nameText(X509_get_issuer_name(gCerts[h]))
}

@(private)
sinceEpochMs :: proc(t: rawptr) -> int {
	epoch := ASN1_TIME_set(nil, 0)
	days, secs: c.int
	if ASN1_TIME_diff(&days, &secs, epoch, t) != 1 do return 0
	return int(days) * 86_400_000 + int(secs) * 1000
}

certNotBeforeMs :: proc(h: int) -> int {
	if !certValid(h) do return 0
	return sinceEpochMs(X509_getm_notBefore(gCerts[h]))
}

certNotAfterMs :: proc(h: int) -> int {
	if !certValid(h) do return 0
	return sinceEpochMs(X509_getm_notAfter(gCerts[h]))
}

@(private)
connValid :: proc(cn: int) -> bool { return cn >= 0 && cn < len(gConns) && gConns[cn].live }

// A connection handle >= 0; -1 no TCP, -2 handshake refused, -3 verification
// failed (only when `verify` is 1).
tlsConnect :: proc(host: string, port: int, verify: int) -> int {
	target := strings.concatenate({host, ":", itoa(port)}, context.temp_allocator)
	sock, derr := net.dial_tcp_from_hostname_and_port_string(target)
	if derr != nil do return -1
	ctx := SSL_CTX_new(TLS_client_method())
	if ctx == nil do return -2
	SSL_CTX_set_default_verify_paths(ctx)
	SSL_CTX_set_verify(ctx, verify == 1 ? 1 : 0, nil)
	s := SSL_new(ctx)
	SSL_set_fd(s, c.int(sock))
	chost := strings.clone_to_cstring(host, context.temp_allocator)
	SSL_ctrl(s, 55, 0, rawptr(chost))
	if SSL_connect(s) != 1 {
		bad := verify == 1 && SSL_get_verify_result(s) != 0
		SSL_free(s)
		SSL_CTX_free(ctx)
		net.close(sock)
		return bad ? -3 : -2
	}
	append(&gConns, Conn{ssl = s, ctx = ctx, sock = sock, live = true})
	return len(gConns) - 1
}

@(private)
itoa :: proc(n: int) -> string {
	buf: [20]u8
	i := len(buf)
	v := n
	if v == 0 { return "0" }
	for v > 0 { i -= 1; buf[i] = u8('0' + v % 10); v /= 10 }
	return strings.clone(string(buf[i:]), context.temp_allocator)
}

tlsChainLen :: proc(cn: int) -> int {
	if !connValid(cn) do return 0
	st := SSL_get_peer_cert_chain(gConns[cn].ssl)
	if st == nil do return 0
	return int(OPENSSL_sk_num(st))
}

// A certificate handle for the i-th certificate the peer sent (leaf first), or -1.
tlsChainCert :: proc(cn: int, i: int) -> int {
	if !connValid(cn) do return -1
	st := SSL_get_peer_cert_chain(gConns[cn].ssl)
	if st == nil || i < 0 || i >= int(OPENSSL_sk_num(st)) do return -1
	append(&gCerts, OPENSSL_sk_value(st, c.int(i)))
	return len(gCerts) - 1
}

tlsSend :: proc(cn: int, data: string) -> int {
	if !connValid(cn) || len(data) == 0 do return 0
	return int(SSL_write(gConns[cn].ssl, raw_data(data), c.int(len(data))))
}

tlsRecv :: proc(cn: int, max_: int) -> [dynamic]u8 {
	out := make([dynamic]u8)
	if !connValid(cn) || max_ <= 0 do return out
	buf := make([]u8, max_, context.temp_allocator)
	n := int(SSL_read(gConns[cn].ssl, raw_data(buf), c.int(max_)))
	if n <= 0 do return out
	for i in 0 ..< n do append(&out, buf[i])
	return out
}

tlsClose :: proc(cn: int) {
	if !connValid(cn) do return
	SSL_shutdown(gConns[cn].ssl)
	SSL_free(gConns[cn].ssl)
	SSL_CTX_free(gConns[cn].ctx)
	net.close(gConns[cn].sock)
	gConns[cn].live = false
}
