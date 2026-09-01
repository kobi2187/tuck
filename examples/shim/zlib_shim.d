// D impl module for examples/34-ffi-cstring — the twin of zlib_shim.nim/.odin.
//
// Same contract, same reason: the `char*` stops here and a Tuck-owned string
// crosses. Written separately rather than shared because the FFI spelling IS
// the target language (D's pragma(mangle) vs Nim's {.importc.} vs Odin's
// foreign), which is the same rule codegen.nim states: share the logic,
// never share the syntax.
module zlib_shim;

import std.string : fromStringz;

pragma(lib, "z");

// pragma(mangle) keeps the C symbol while freeing the D identifier, so the
// PUBLIC fn below can carry the name the Tuck extern declares — the emitted
// forwarder calls <alias>.zlibVersion and must find it here.
pragma(mangle, "zlibVersion")
extern (C) private const(char)* zlibVersionRaw();

string zlibVersion()
{
    // fromStringz is a VIEW into libz's own memory; .idup copies it into a
    // D-owned string before it crosses into Tuck.
    return fromStringz(zlibVersionRaw()).idup;
}
