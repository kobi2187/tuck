# Pinned SVD input

`STM32F103.svd` comes from `modm-io/cmsis-svd-stm32`, path
`stm32f1/STM32F103.svd`, Apache-2.0 licensed; see `LICENSE-APACHE.md`.

Chosen over svd2nim's bundled copy of the same file, which carries no explicit
licence header. The Blue Pill board in `testing_experiment/boards/` is an
STM32F103, so this input pins T8's zero-register-diff fixture.

Regenerate with `../regenerate.sh` from the parent directory.
