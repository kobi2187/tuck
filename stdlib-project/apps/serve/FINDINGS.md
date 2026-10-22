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
- The first draft called `accept` from `main` and aborted with "cannot await
  outside a coroutine" on every backend, though `tuck ch` accepted it. Ruled
  2026-10-22 that any fn declaring `[io]`/`[io: net]` may wait; fixed as A94
  (issue #183). The server keeps its task per connection, which is what lets
  slow clients not hold each other up.
