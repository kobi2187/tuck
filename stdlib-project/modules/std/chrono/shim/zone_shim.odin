// Odin impl module for std.chrono's time zones — the twin of zone_shim.nim.
// The rules are the OS tz database read through libc. NOT thread-safe: libc
// keeps the zone in the TZ variable.
package zone_shim

import "core:c"
import "core:os"
import "core:strings"

foreign import libc "system:c"

@(private) Tm :: struct {
	f:        [9]c.int,
	pad:      c.int,
	gmtoff:   c.long,
	zone:     cstring,
}

@(default_calling_convention = "c", private)
foreign libc {
	localtime_r :: proc(t: ^c.long, tm: ^Tm) -> rawptr ---
	tzset :: proc() ---
	setenv :: proc(name: cstring, value: cstring, overwrite: c.int) -> c.int ---
}

@(private) NoZone :: 999999

@(private)
zoneOk :: proc(zone: string) -> bool {
	if len(zone) == 0 || zone[0] == '/' || zone[0] == ':' || strings.contains(zone, "..") do return false
	if zone == "UTC" do return true
	path := strings.concatenate({"/usr/share/zoneinfo/", zone}, context.temp_allocator)
	return os.exists(path)
}

@(private)
here :: proc(zone: string, t: int, tm: ^Tm) -> bool {
	if !zoneOk(zone) do return false
	czone := strings.clone_to_cstring(zone, context.temp_allocator)
	setenv("TZ", czone, 1)
	tzset()
	tt := c.long(t)
	return localtime_r(&tt, tm) != nil
}

// Seconds east of UTC in force then, or 999999 for an unknown zone.
tzOffsetAt :: proc(zone: string, epochSec: int) -> int {
	tm: Tm
	if !here(zone, epochSec, &tm) do return NoZone
	return int(tm.gmtoff)
}

tzIsDst :: proc(zone: string, epochSec: int) -> int {
	tm: Tm
	if !here(zone, epochSec, &tm) do return 0
	return tm.f[8] > 0 ? 1 : 0
}

tzAbbrev :: proc(zone: string, epochSec: int) -> [dynamic]u8 {
	out := make([dynamic]u8)
	tm: Tm
	if !here(zone, epochSec, &tm) || tm.zone == nil do return out
	s := string(tm.zone)
	for i in 0 ..< len(s) do append(&out, s[i])
	return out
}
