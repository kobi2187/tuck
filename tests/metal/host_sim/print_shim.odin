// Odin host shim for the embedded experiment — twin of print_shim.nim.
// The emitted forwarder imports the whole host_sim directory as one package,
// so this file shares `package host_sim` with hal_shim.odin. Output is the
// same text the Nim shim writes through stdout, so a three-target host run
// produces byte-identical observable behaviour.
package host_sim

import "core:fmt"

say :: proc(text: string) {
	fmt.print(text)
}
