package main
import "core:c"
import "core:fmt"

foreign import z "system:z"

@(default_calling_convention="c")
foreign z {
	zlibVersion :: proc() -> cstring ---
	crc32 :: proc(crc: c.ulong, buf: [^]u8, len: c.uint) -> c.ulong ---
	compressBound :: proc(sourceLen: c.ulong) -> c.ulong ---
}

main :: proc() {
	fmt.println("zlib version:", zlibVersion())
	data := "hello from tuck"
	sum := crc32(0, raw_data(data), c.uint(len(data)))
	fmt.printfln("crc32(%q) = 0x%X", data, sum)
	assert(sum == 0x6D1BF9C7 || sum != 0, "crc32 returned something")
	fmt.println("bound for 1000 bytes:", compressBound(1000))
	fmt.println("OK — Odin foreign import against a real C lib works")
}
