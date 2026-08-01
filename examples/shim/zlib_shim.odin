// Odin impl module for examples/34-ffi-cstring — the twin of zlib_shim.nim.
//
// Same contract, same reason: the `char*` stops here and a Tuck-owned string
// crosses. Written separately rather than shared because the FFI spelling IS
// the target language (Nim `{.importc.}` vs Odin `foreign`), which is the same
// rule codegen.nim's header states: share the logic, never share the syntax.
package zlib_shim

import "core:strings"

foreign import z "system:z"

// @(link_name) keeps the C symbol while freeing the Odin identifier, so the
// PUBLIC proc below can carry the name the Tuck extern declares — the emitted
// forwarder calls <alias>.zlibVersion and must find it here.
@(default_calling_convention = "c")
foreign z {
	@(link_name = "zlibVersion")
	zlibVersionRaw :: proc() -> cstring ---
}

zlibVersion :: proc() -> string {
	return strings.clone_from_cstring(zlibVersionRaw())
}
