# Nim impl module for std.net-tls' OpenSSL driver — twins: openssl_shim.odin and
# openssl_shim.d. X509 and SSL pointers stay in these tables; Tuck holds
# HANDLES (indexes) and reads a certificate's subject, issuer and validity as
# text and milliseconds-since-epoch. Names are the CommonName (CN), which is
# what a hostname is matched against.
{.passL: "-lssl -lcrypto".}
import std/net

proc BIO_new_mem_buf(buf: pointer, len: cint): pointer {.importc, cdecl.}
proc BIO_free(b: pointer): cint {.importc, cdecl.}
proc PEM_read_bio_X509(bio, x, cb, u: pointer): pointer {.importc, cdecl.}
proc X509_get_subject_name(x: pointer): pointer {.importc, cdecl.}
proc X509_get_issuer_name(x: pointer): pointer {.importc, cdecl.}
proc X509_NAME_get_text_by_NID(n: pointer, nid: cint, buf: cstring, len: cint): cint {.importc, cdecl.}
proc X509_getm_notBefore(x: pointer): pointer {.importc, cdecl.}
proc X509_getm_notAfter(x: pointer): pointer {.importc, cdecl.}
proc ASN1_TIME_set(s: pointer, t: clong): pointer {.importc, cdecl.}
proc ASN1_TIME_diff(pday, psec: ptr cint, frm, to: pointer): cint {.importc, cdecl.}
proc TLS_client_method(): pointer {.importc, cdecl.}
proc SSL_CTX_new(m: pointer): pointer {.importc, cdecl.}
proc SSL_CTX_set_default_verify_paths(c: pointer): cint {.importc, cdecl.}
proc SSL_CTX_set_verify(c: pointer, mode: cint, cb: pointer) {.importc, cdecl.}
proc SSL_new(c: pointer): pointer {.importc, cdecl.}
proc SSL_set_fd(s: pointer, fd: cint): cint {.importc, cdecl.}
proc SSL_ctrl(s: pointer, cmd: cint, larg: clong, parg: pointer): clong {.importc, cdecl.}
proc SSL_connect(s: pointer): cint {.importc, cdecl.}
proc SSL_read(s: pointer, buf: pointer, n: cint): cint {.importc, cdecl.}
proc SSL_write(s: pointer, buf: pointer, n: cint): cint {.importc, cdecl.}
proc SSL_shutdown(s: pointer): cint {.importc, cdecl.}
proc SSL_free(s: pointer) {.importc, cdecl.}
proc SSL_CTX_free(c: pointer) {.importc, cdecl.}
proc SSL_get_peer_cert_chain(s: pointer): pointer {.importc, cdecl.}
proc SSL_get_verify_result(s: pointer): clong {.importc, cdecl.}
proc OPENSSL_sk_num(st: pointer): cint {.importc, cdecl.}
proc OPENSSL_sk_value(st: pointer, i: cint): pointer {.importc, cdecl.}

type Conn = object
  ssl, ctx: pointer
  sock: Socket
  live: bool

var gCerts: seq[pointer]
var gConns: seq[Conn]

proc certValid(h: int): bool = h >= 0 and h < gCerts.len and gCerts[h] != nil

proc certFromPem*(pem: string): int =
  ## A certificate handle >= 0, or -1 when the text is not a PEM certificate.
  let bio = BIO_new_mem_buf(pem.cstring, cint(pem.len))
  if bio == nil: return -1
  let x = PEM_read_bio_X509(bio, nil, nil, nil)
  discard BIO_free(bio)
  if x == nil: return -1
  gCerts.add x
  gCerts.len - 1

proc nameText(n: pointer): seq[uint8] =
  var buf: array[256, char]
  let k = X509_NAME_get_text_by_NID(n, 13, cast[cstring](addr buf[0]), 256)
  for i in 0 ..< max(int k, 0): result.add uint8(buf[i])

proc certSubject*(h: int): seq[uint8] =
  if not certValid(h): return @[]
  nameText(X509_get_subject_name(gCerts[h]))

proc certIssuer*(h: int): seq[uint8] =
  if not certValid(h): return @[]
  nameText(X509_get_issuer_name(gCerts[h]))

proc sinceEpochMs(t: pointer): int =
  let epoch = ASN1_TIME_set(nil, 0)
  var days, secs: cint
  if ASN1_TIME_diff(addr days, addr secs, epoch, t) != 1: return 0
  int(days) * 86_400_000 + int(secs) * 1000

proc certNotBeforeMs*(h: int): int =
  if not certValid(h): return 0
  sinceEpochMs(X509_getm_notBefore(gCerts[h]))

proc certNotAfterMs*(h: int): int =
  if not certValid(h): return 0
  sinceEpochMs(X509_getm_notAfter(gCerts[h]))

proc connValid(c: int): bool = c >= 0 and c < gConns.len and gConns[c].live

proc tlsConnect*(host: string, port: int, verify: int): int =
  ## A connection handle >= 0; -1 no TCP, -2 handshake refused, -3 verification
  ## failed (only when `verify` is 1).
  var sock: Socket
  try:
    sock = newSocket()
    sock.connect(host, Port(port))
  except CatchableError:
    return -1
  let ctx = SSL_CTX_new(TLS_client_method())
  if ctx == nil: return -2
  discard SSL_CTX_set_default_verify_paths(ctx)
  SSL_CTX_set_verify(ctx, (if verify == 1: 1 else: 0), nil)
  let ssl = SSL_new(ctx)
  discard SSL_set_fd(ssl, cint(sock.getFd()))
  discard SSL_ctrl(ssl, 55, 0, host.cstring)
  if SSL_connect(ssl) != 1:
    let bad = verify == 1 and SSL_get_verify_result(ssl) != 0
    SSL_free(ssl); SSL_CTX_free(ctx); sock.close()
    return (if bad: -3 else: -2)
  gConns.add Conn(ssl: ssl, ctx: ctx, sock: sock, live: true)
  gConns.len - 1

proc tlsChainLen*(c: int): int =
  if not connValid(c): return 0
  let st = SSL_get_peer_cert_chain(gConns[c].ssl)
  if st == nil: return 0
  int OPENSSL_sk_num(st)

proc tlsChainCert*(c, i: int): int =
  ## A certificate handle for the i-th certificate the peer sent (leaf first), or -1.
  if not connValid(c): return -1
  let st = SSL_get_peer_cert_chain(gConns[c].ssl)
  if st == nil or i < 0 or i >= int OPENSSL_sk_num(st): return -1
  gCerts.add OPENSSL_sk_value(st, cint(i))
  gCerts.len - 1

proc tlsSend*(c: int, data: string): int =
  if not connValid(c) or data.len == 0: return 0
  int SSL_write(gConns[c].ssl, data.cstring, cint(data.len))

proc tlsRecv*(c, max: int): seq[uint8] =
  if not connValid(c) or max <= 0: return @[]
  var buf = newSeq[uint8](max)
  let n = int SSL_read(gConns[c].ssl, addr buf[0], cint(max))
  if n <= 0: return @[]
  buf.setLen n
  buf

proc tlsClose*(c: int) =
  if not connValid(c): return
  discard SSL_shutdown(gConns[c].ssl)
  SSL_free(gConns[c].ssl)
  SSL_CTX_free(gConns[c].ctx)
  gConns[c].sock.close()
  gConns[c].live = false
