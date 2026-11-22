# svd2tuck — backlog

## Done

- **CLEAR** Vendor the MIT parser front half with attribution — done.
- **CLEAR** Emit absolute-address `register` declarations from `SvdDevice` — done.
- **CLEAR** Sanitise identifiers for Tuck and Nim (no `__`, no reserved words) — done.
- **CLEAR** Map SVD access modes to `[read]`/`[write]`, note losses — done.
- **CLEAR** JSON overlay: `onlyPeripherals`, `omitRegisters`, `renameRegisters`,
  `forceAccess` — done.
- **CLEAR** Generate and commit STM32F103 + Blue Pill modules from a licensed
  SVD — done.
- **CLEAR** Pin zero-diff and imported-accessor behaviour in
  `tests/suites/svd_import.nim` — done (11 assertions).
- **CLEAR** Boot the generated-register fixture under QEMU — done (`124`,
  identical to the hand-written fixture).

## Parked

- **OPEN** Field-level overlay (drop/rename one field) — no consumer yet.
- **OPEN** Multi-instance peripherals — needs `--prefix` at board scale.
- **OPEN** Emit a `main` of self-checks (parent T10) — needs a checker decision.
