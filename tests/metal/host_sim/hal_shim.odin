// Odin host shim for the embedded experiment — twin of hal_shim.nim.
// Same package as print_shim.odin (the emitted import names the directory),
// same observable lines. No register block is touched: the real addresses
// live in hal_stm32.tuck, and on the host these procs are the HAL.
package host_sim

import "core:fmt"

ledOn :: proc() {
	fmt.println("LED ON")
}

ledOff :: proc() {
	fmt.println("LED OFF")
}

delayMs :: proc(ms: int) {
	// No wall-clock wait: virtual time is the QEMU loop's job.
}

regWrite :: proc(a: u32, value: u32) {
	fmt.printf("REG WRITE %d = %d\n", a, value)
}

regRead :: proc(a: u32) -> u32 {
	return 0
}

buttonPressed :: proc() -> bool {
	return false
}

uartHasByte :: proc() -> bool {
	return false
}

uartReadByte :: proc() -> u8 {
	return 0
}

uartWriteByte :: proc(b: u8) {
	fmt.printf("UART TX %d\n", b)
}

ledSet :: proc(id: u8, lit: bool) {
	if lit {
		fmt.printf("LED %d ON\n", id)
	} else {
		fmt.printf("LED %d OFF\n", id)
	}
}

applyState :: proc(l0: bool, l1: bool) {
	fmt.printf("STATE l0=%v l1=%v\n", l0, l1)
}
