# alloc.fmt — Tuck translation

## This module folds into `core.fmt`.

Its stated purpose was *"turn values into `Text`… not a single new concept
— this is `core.fmt`'s existing machinery pointed at an allocator."* Two
things it existed for are both gone in Tuck:

1. **The owned/borrowed text split.** There is no `Text` vs `TextView` —
   only `str` (see `core.str`, `alloc.string`). So "the allocating version
   of formatting" isn't a separate thing to be.
2. **Allocator choice.** No `Memory` handle to point at
   (see `alloc.allocator`); regions are `pool`/`arena` declarations.

And `core.fmt`'s Tuck form already returns `str` rather than writing into a
`TextSink` (the sink couldn't survive value semantics — a callee cannot
write through a parameter). So `core.fmt::show`/`render` *is* what this
module was going to provide.

## What survives, and where it goes
- **String interpolation / `fmt"..."`-style formatting** — genuinely useful
  and not yet specified anywhere in the Tuck translation. It belongs in
  `core.fmt` beside `show`, not in a separate module. Not designed here:
  whether Tuck wants a format-string macro, or just
  `join`/`append`/`padLeft` composition, is an open call — and the
  `PROTOCOLS.md` instinct ("a module that needs many novel verbs belongs
  elsewhere") argues for the plain-composition answer.

## Recommendation
Drop as a module; keep the interpolation question open against `core.fmt`.
