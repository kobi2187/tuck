# svd2tuck

`CMSIS-SVD file -> one importable Tuck module`. Standalone Nim tool; output is
plain Tuck text using the existing `register NAME at 0xADDR:` construct.

```sh
./regenerate.sh                 # rebuild + regenerate both committed modules
```

Manual use:

```sh
nim c --hints:off -o:/tmp/svd2tuck src/svd2tuck.nim
/tmp/svd2tuck svd/STM32F103.svd --out generated
/tmp/svd2tuck svd/STM32F103.svd --overlay bluepill.json \
  --module stm32f103_bluepill --out generated
```

Options: `--out DIR`, `--module NAME`, `--prefix NAME` (for programs with two
devices), `--overlay FILE`, `-h/--help`.

An overlay is JSON:

```json
{
  "onlyPeripherals": ["RCC", "GPIOC"],
  "omitRegisters": ["RCC_OLD"],
  "renameRegisters": {"GPIOC_ODR": "LED_PORT"},
  "forceAccess": {"GPIOC_ODR.ODR13": "write"}
}
```

## Output rules

- Register names are `<PERIPHERAL>_<REGISTER>`; field names are kept, with
  Tuck keywords and Nim's doubled-underscore prohibition sanitised away.
- Addresses are absolute (`peripheral base + register offset`).
- `read`/`write` map to `[read]` / `[write]`; an unmarked field is both.
  `writeOnce` and `read-writeOnce` degrade with a `# Note:` line.
- Notes at the top of the module say what was dropped: reset values, field
  enums, modified-write values, read actions, write-once semantics.
- Duplicate register names are skipped with a note: Tuck's register namespace
  is program-global. Use `--prefix`.

## Verification

From the repository root:

```sh
./tests/run svd_import
TUCK_STDLIB=tools/svd2tuck/generated \
  ./tools/metal/qemu-run.sh boot_led_svd
```

The first pins imported accessors on Nim/Odin/D, the 32-bit field mask, and
zero diff on the five registers shared with `boot_led.tuck`. The second
boots the generated-register program on QEMU (`124` = clean idle loop).

## Provenance

- `vendor/` is EmbeddedNim/svd2nim v0.6.2 (MIT), front half only; see
  `vendor/LICENSE-MIT` and `vendor/README.md`.
- `svd/` is `modm-io/cmsis-svd-stm32` (Apache-2.0); see `svd/README.md`.
