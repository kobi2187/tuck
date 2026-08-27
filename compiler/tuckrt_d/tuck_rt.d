// compiler/tuckrt_d/tuck_rt.d
//
// The Tuck runtime for the D backend — the counterpart of tuck_rt.nim (Nim)
// and tuckrt/tuck_rt.odin (Odin). Copied beside the emitted .d files by
// `tuck c --dlang`; emitted code reaches it as `import rt = tuck_rt;`.
//
// Grown lazily: a helper exists here only once emitted code actually calls
// it. Semantics must match tuck_rt.nim exactly — where D offers a native
// construct with identical behaviour (templates over $-stringification,
// writeln), it is used; where semantics would drift, the Nim shape is ported.
module tuck_rt;

import std.stdio : stdout;
import std.conv : text;

// std/console — terminal I/O (rt-implemented externs).
void print(string s) { stdout.write(s); stdout.flush(); }
void printLine(string s) { stdout.writeln(s); }

// `toStr` — the universal stringifier. tuck_rt.nim spells it `$value`; D's
// std.conv.text is the same "any value to its display form" operation.
string toStr(T)(T value) { return text(value); }
