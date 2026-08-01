# Nim impl module for examples/34-ffi-cstring.
#
# The pointer stops here. Tuck's rule is that a raw pointer may be passed INTO
# C but never returned out of it: a returned `char*` would land in a Tuck
# variable whose lifetime is C's business and unknowable to the checker. So the
# C binding lives in this file — where `cstring` is an ordinary Nim type — and
# what crosses into Tuck is a `string`, copied.
#
# zlibVersion() returns a static string owned by libz, so there is nothing to
# free and the pointer outlives the call. That fact is checkable HERE, next to
# the binding, which is the point: the unsafe reasoning sits in one small file
# instead of being a convention every call site has to remember.
{.passL: "-lz".}

proc zlibVersionRaw(): cstring {.importc: "zlibVersion", header: "zlib.h".}

proc zlibVersion*(): string =
  ## libz's version, copied out of C's memory into a Tuck-owned string.
  $zlibVersionRaw()
