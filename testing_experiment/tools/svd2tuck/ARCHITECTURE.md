# svd2tuck — architecture

## Module tree

```
vendor/     Svd XML parser, typed model, transformations, identifier utils
            (verbatim MIT copy of EmbeddedNim/svd2nim's front half)
src/        OVERLAY (JSON) + EMITTER (SVD -> Tuck register text) + CLI
svd/        Pinned Apache-2.0 CMSIS-SVD input and its licence
generated/  Committed output: one .tuck module per generation run
```

Status: EMITTER BUILT, PARSER BUILT (vendored), OVERLAY BUILT,
GENERATED BUILT. All interfaces are local to this tool; the only cross-boundary
contract is the emitted Tuck `register NAME at 0xADDR:` surface.

## Assembly plan

`regenerate.sh` builds the Nim binary from `src/ + vendor/`, then runs it twice
over `svd/STM32F103.svd`: once for the whole device, once with `bluepill.json`
for the five registers the QEMU board fixture uses. The parent project imports
the small module via `--stdlib:testing_experiment/tools/svd2tuck/generated`.

## Seams under tension

- **Name sanitisation.** Tuck's identifier alphabet plus Nim 2.x's ban on
  doubled underscores means SVD names are lossy. Collisions are reported as
  notes and duplicate register names are skipped, never silently merged.
- **Access mapping.** `read`/`write` come through directly; `writeOnce` and
  `read-writeOnce` degrade to `[write]` / `[read, write]` with a note.
- **Full-width fields.** `bits 0..31` is real in SVD. The compiler's mask
  generation was changed to shift a full word right rather than `1` left by 32
  in all three backends; the emitter does not special-case it.

## Drift log

- 2026-11-21: generation target changed from the whole device to
  `stm32f103_bluepill.tuck` after whole-device Nim host compilation measured
  102 s; the full-device module remains committed for scale.
