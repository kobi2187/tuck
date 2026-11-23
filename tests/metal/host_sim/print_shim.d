// D host shim for the embedded experiment — twin of print_shim.nim.
// The emitted forwarder imports this module by bare name (the `impl: d`
// path points at this file), and calls print_shim.say. `write` adds no
// newline, matching Nim's stdout.write so all three backends emit the same
// bytes for the same Tuck program.
module print_shim;

import std.stdio : write;

void say(string text)
{
    write(text);
}
