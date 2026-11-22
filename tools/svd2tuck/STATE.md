# svd2tuck — state

Green as of 2026-11-21, on branch `claude/freestanding-baremetal-qemu`.

Generated `stm32f103.tuck`: 955 registers / 6,826 fields, 258 KB, `tuck ch` in
~150 ms; Nim host codegen takes ~102 s, so tests use the overlay build.
Generated `stm32f103_bluepill.tuck`: 17 registers / 271 fields, 310 lines,
`tuck ch` in ~12 ms; all three backends build it in ~0.3–1.2 s.

Verified: `./tests/run svd_import` 11/11; `./tuck ch/b` on the fixture for Nim,
Odin and D; QEMU `qemu-run.sh boot_led_svd` exits 124 (clean
idle loop), same as `boot_led.tuck`.

What got unblocked: T8's import seam is real — registers can cross module
boundaries, and Odin/D qualify their accessors to the defining module.
