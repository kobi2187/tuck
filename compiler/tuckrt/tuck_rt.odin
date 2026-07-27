// compiler/tuckrt/tuck_rt.odin
//
// The Odin backend's runtime, mirroring compiler/tuck_rt.nim's contract:
// TuckResult (the !T/?T carrier), saturating arithmetic, bump arenas, object
// pools, mailboxes, and the stdlib externs std/*.tuck declares.
//
// Generated Odin imports this as `rt`, so every entry point here is what
// codegen_odin.nim emits as `rt.<name>`.
//
// Unlike the Nim runtime this needs no locks: Tuck is single-threaded and
// cooperative (actors and tasks are coroutines on one scheduler), so a
// mailbox is only ever touched between yield points.
package tuckrt

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// !T is a result, ?T is an option: absence is a first-class state, not a
// reserved error code. !T uses Ok/Err, ?T uses Ok/Absent, !?T may be any.
TuckStatus :: enum u8 {
	Ok,
	Err,
	Absent,
}

// Payload for a fn returning `!void` — Odin has no empty tuple type.
TuckUnit :: struct {}

TuckResult :: struct($T: typeid) {
	status: TuckStatus,
	err:    u16, // app-wide error code; meaningful only when status == .Err
	value:  T,
}

ok :: proc(r: TuckResult($T)) -> bool {
	return r.status == .Ok
}

tok :: proc(v: $T) -> TuckResult(T) {
	return TuckResult(T){status = .Ok, value = v}
}

tokVoid :: proc() -> TuckResult(TuckUnit) {
	return TuckResult(TuckUnit){status = .Ok}
}

terr :: proc($T: typeid, code: u16) -> TuckResult(T) {
	return TuckResult(T){status = .Err, err = code}
}

tnone :: proc($T: typeid) -> TuckResult(T) {
	return TuckResult(T){status = .Absent}
}

// `?` propagation: forward failure OR absence unchanged (status-preserving)
tfwd :: proc($T: typeid, status: TuckStatus, err: u16) -> TuckResult(T) {
	return TuckResult(T){status = status, err = err}
}

tuckReportUnhandled :: proc(code: u16, site: string) {
	fmt.eprintfln("TUCK UNHANDLED: error %d at %s", code, site)
}

// Same FNV-1a fold as tuck_rt.nim's errCode and the emitter's odinErrCode:
// stable across builds and backends, no tables.
errCode :: proc(name: string) -> u16 {
	h: u32 = 2166136261
	for c in transmute([]u8)name {
		h = (h ~ u32(c)) * 16777619
	}
	return u16((h ~ (h >> 16)) & 0xFFFF)
}

toStr :: proc(value: $T) -> string {
	return fmt.aprint(value)
}

tuckConcat :: proc(a, b: string) -> string {
	return strings.concatenate({a, b})
}

// seq access. Bounds are a PRECONDITION: violating one is a program error,
// not an error value the caller matches.
at :: proc(items: []$T, index: int) -> T {
	assert(index >= 0 && index < len(items), "at: index out of bounds")
	return items[index]
}

setAt :: proc(items: []$T, index: int, value: T) {
	assert(index >= 0 && index < len(items), "setAt: index out of bounds")
	items[index] = value
}

// `[saturating]` (spec 4.1): clamp at the type's bounds instead of wrapping.
// VALUE SEMANTICS, not an assertion — never stripped in release, because
// removing it would change results. Runs on a wider intermediate so a chain
// clamps once against the final value rather than at every operator.
tuckSat :: proc($T: typeid, v: u64) -> T {
	return v > u64(max(T)) ? max(T) : T(v)
}

tuckSatI :: proc($T: typeid, v: i64) -> T {
	if v > i64(max(T)) do return max(T)
	if v < i64(min(T)) do return min(T)
	return T(v)
}

// spec 7.2: a fixed byte buffer handed out by bumping a cursor. No
// fragmentation, no per-object free — reset reclaims everything at once.
BumpArena :: struct($Size: int) {
	buffer: [Size]u8,
	cursor: int,
}

alloc :: proc(arena: ^BumpArena($Size), bytes: int) -> rawptr {
	assert(arena.cursor + bytes <= Size, "Arena buffer exhausted")
	ptr := rawptr(&arena.buffer[arena.cursor])
	arena.cursor += bytes
	return ptr
}

reset :: proc(arena: ^BumpArena($Size)) {
	arena.cursor = 0
}

// spec 7.2: N slots of an arbitrary T plus an occupancy bitmask. Fixed size,
// no fragmentation, O(1) release. Exhaustion is ABSENCE (?T), not nil and not
// an error — the caller decides what running out means for its situation.
ObjectPool :: struct($T: typeid, $Count: int) {
	storage:  [Count]T,
	occupied: u64, // ponytail: 64 slots max; widen to an array if needed
}

acquire :: proc(pool: ^ObjectPool($T, $Count)) -> TuckResult(T) {
	for i in 0 ..< Count {
		if (pool.occupied & (u64(1) << u64(i))) == 0 {
			pool.occupied |= u64(1) << u64(i)
			return tok(pool.storage[i])
		}
	}
	return tnone(T)
}

release :: proc(pool: ^ObjectPool($T, $Count), item: T) {
	// Which slot did this come from? The value was handed out from one of
	// these cells, so match it back by equality.
	for i in 0 ..< Count {
		if pool.storage[i] == item {
			pool.occupied &~= u64(1) << u64(i)
			return
		}
	}
}

// Actor mailbox: a fixed ring. Single-threaded and cooperative, so unlike the
// Nim runtime there is no lock — sends and drains never interleave mid-op.
Mailbox :: struct($T: typeid, $Cap: int) {
	data: [Cap]T,
	head: int,
	tail: int,
}

enqueue :: proc(mb: ^Mailbox($T, $Cap), msg: T) -> bool {
	next := (mb.tail + 1) % Cap
	if next == mb.head do return false // full: sendX drops (spec §9.1)
	mb.data[mb.tail] = msg
	mb.tail = next
	return true
}

dequeue :: proc(mb: ^Mailbox($T, $Cap), msg: ^T) -> bool {
	if mb.head == mb.tail do return false
	msg^ = mb.data[mb.head]
	mb.head = (mb.head + 1) % Cap
	return true
}

// Sender's opt-in backpressure check. sendX drops silently on a full ring
// (fast, non-blocking, spec §9.1) — the sender may check first if it cares.
hasRoom :: proc(mb: ^Mailbox($T, $Cap)) -> bool {
	return ((mb.tail + 1) % Cap) != mb.head
}

// ---------- stdlib externs (std/*.tuck) ----------
// Odin's core IS Tuck's OS layer here, the way Nim's stdlib is on that side.
// Every fallible fn returns terr(errCode("module/Enum.Variant")) matching the
// error enums the std/*.tuck signatures declare, so failures never escape as
// panics. The code strings are MODULE-QUALIFIED and must stay byte-identical
// to tuck_rt.nim's — both are hashed by the same FNV-1a fold, so a mismatch
// would silently produce different error codes per backend.
//
// Returns are record-shaped ({content: str}, {line: str}, ...) because the
// Tuck signatures declare them that way; the emitter matches these fields to
// params by name.

FsContent :: struct {
	content: string,
}

IoLine :: struct {
	line: string,
}

EnvValue :: struct {
	value: string,
}

ArgCount :: struct {
	count: int,
}

ArgValue :: struct {
	arg: string,
}

NowMs :: struct {
	ms: u64,
}

// --- std/fs ---

readFile :: proc(path: string) -> TuckResult(FsContent) {
	if !os.exists(path) do return terr(FsContent, errCode("fs/FsError.NotFound"))
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil do return terr(FsContent, errCode("fs/FsError.IoFailed"))
	return tok(FsContent{content = string(data)})
}

writeFile :: proc(path: string, content: string) -> TuckResult(TuckUnit) {
	err := os.write_entire_file(path, transmute([]u8)content)
	if err != nil do return terr(TuckUnit, errCode("fs/FsError.AccessDenied"))
	return tokVoid()
}

appendFile :: proc(path: string, content: string) -> TuckResult(TuckUnit) {
	f, err := os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREATE, os.Permissions{.Read_User, .Write_User, .Read_Group, .Read_Other})
	if err != nil do return terr(TuckUnit, errCode("fs/FsError.AccessDenied"))
	defer os.close(f)
	_, werr := os.write(f, transmute([]u8)content)
	if werr != nil do return terr(TuckUnit, errCode("fs/FsError.AccessDenied"))
	return tokVoid()
}

removeFile :: proc(path: string) -> TuckResult(TuckUnit) {
	if !os.exists(path) do return terr(TuckUnit, errCode("fs/FsError.NotFound"))
	if os.remove(path) != nil {
		return terr(TuckUnit, errCode("fs/FsError.AccessDenied"))
	}
	return tokVoid()
}

fileExists :: proc(path: string) -> bool {
	return os.exists(path)
}

// --- std/io ---

print :: proc(text: string) {
	fmt.print(text)
}

printLine :: proc(text: string) {
	fmt.println(text)
}

readLine :: proc() -> TuckResult(IoLine) {
	buf: [4096]u8
	n, err := os.read(os.stdin, buf[:])
	if err != nil do return terr(IoLine, errCode("io/IoError.IoFailed"))
	if n <= 0 do return terr(IoLine, errCode("io/IoError.EndOfInput"))
	line := strings.trim_right(string(buf[:n]), "\r\n")
	return tok(IoLine{line = strings.clone(line)})
}

// --- std/sys ---

argCount :: proc() -> ArgCount {
	// Tuck counts arguments the way Nim's paramCount does: excluding argv[0].
	return ArgCount{count = max(len(os.args) - 1, 0)}
}

argAt :: proc(index: int) -> ArgValue {
	if index < 0 || index + 1 >= len(os.args) do return ArgValue{arg = ""}
	return ArgValue{arg = os.args[index + 1]}
}

getEnv :: proc(name: string) -> TuckResult(EnvValue) {
	// Absence is ?T, not an error — the caller decides what unset means.
	value, found := os.lookup_env(name, context.allocator)
	if !found do return tnone(EnvValue)
	return tok(EnvValue{value = value})
}

exit :: proc(code: int) {
	os.exit(code)
}

// --- std/time ---

nowMs :: proc() -> NowMs {
	return NowMs{ms = u64(time.to_unix_nanoseconds(time.now()) / 1_000_000)}
}

sleepMs :: proc(ms: u32) {
	time.sleep(time.Duration(ms) * time.Millisecond)
}
