# serve — findings

`python -m http.server` in Tuck: GET and HEAD over a folder, index.html or a
listing for a folder, Content-Type by extension, `..` refused, one task per
connection. Runs on Nim, Odin and D, curl-checked over real sockets; the
`apps` suite drives it through `--stdio` (one request on stdin, the answer on
stdout, the way inetd and systemd socket activation hand over a connection).

Found on the way:

- `std.net-http` had only the client half. It gained `Request`,
  `parseRequest`, `responseText` and `reasonFor`, checked in its own `main`;
  `parseResponse` now shares the head and header parsing with them.
- `std/console` could not write to stderr, so a server's log either mixed with
  its output or, through a pipe, sat in stdout's buffer until exit. It gained
  `printError`, unbuffered, on all three runtimes.
- Net calls block on the reactor, so they must run inside a task: the first
  draft called `accept` from `main` and aborted with "cannot await outside a
  coroutine" on every backend. That is the documented model (spec §9.2), but
  `tuck ch` accepts the draft; the error arrives only at run time.
