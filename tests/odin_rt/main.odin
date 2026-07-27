// tests/odin_rt/main.odin
// Self-check for compiler/tuckrt/tuck_rt.odin — the Odin backend's runtime.
// Run: odin run tests/odin_rt -out:/tmp/tuck_odin_rt
//
// The error-code assertions are the important ones: they pin Odin's errCode
// to the SAME values codegen_odin.odinErrCode and tuck_rt.nim produce, so the
// two backends can never silently disagree about what an error means.
package main

import "core:fmt"
import "core:os"
import rt "../../compiler/tuckrt"

main :: proc() {
	// --- result carrier ---
	r := rt.tok(42)
	e := rt.terr(int, 7)
	n := rt.tnone(int)
	assert(rt.ok(r) && r.value == 42)
	assert(!rt.ok(e) && e.err == 7 && e.status == .Err)
	assert(n.status == .Absent)
	assert(rt.tokVoid().status == .Ok)
	assert(rt.tfwd(int, .Absent, 0).status == .Absent)

	// --- error codes MUST match the Nim backend's fold exactly ---
	// (ground truth from codegen_odin.odinErrCode, same FNV-1a as tuck_rt.nim)
	assert(rt.errCode("fs/FsError.NotFound") == 42437, "fs NotFound code drift")
	assert(rt.errCode("fs/FsError.IoFailed") == 17552, "fs IoFailed code drift")
	assert(rt.errCode("fs/FsError.AccessDenied") == 33590, "fs AccessDenied drift")
	assert(rt.errCode("io/IoError.EndOfInput") == 13427, "io EndOfInput drift")
	assert(rt.errCode("io/IoError.IoFailed") == 6829, "io IoFailed code drift")

	// --- saturating arithmetic ---
	assert(rt.tuckSat(u8, 300) == 255)
	assert(rt.tuckSat(u8, 200) == 200)
	assert(rt.tuckSatI(i8, -300) == -128)
	assert(rt.tuckSatI(i8, 300) == 127)

	// --- pool: acquire until empty, then ABSENCE (not error) ---
	pool: rt.ObjectPool(int, 2)
	assert(rt.ok(rt.acquire(&pool)))
	assert(rt.ok(rt.acquire(&pool)))
	assert(rt.acquire(&pool).status == .Absent, "exhaustion must be absence")

	// --- mailbox ring: fills, drains FIFO, drops when full ---
	mb: rt.Mailbox(int, 4)
	assert(rt.enqueue(&mb, 1) && rt.enqueue(&mb, 2) && rt.enqueue(&mb, 3))
	assert(!rt.enqueue(&mb, 4), "ring of Cap=4 holds Cap-1")
	assert(!rt.hasRoom(&mb))
	got: int
	assert(rt.dequeue(&mb, &got) && got == 1, "FIFO order")
	assert(rt.dequeue(&mb, &got) && got == 2)
	assert(rt.hasRoom(&mb))

	// --- arena ---
	arena: rt.BumpArena(64)
	_ = rt.alloc(&arena, 32)
	assert(arena.cursor == 32)
	rt.reset(&arena)
	assert(arena.cursor == 0)

	// --- fs round-trip, incl. the error paths ---
	path := "/tmp/claude-1000/-home-kl-prog-tuck-lexer/11cc0e0f-ee53-4e60-84c7-c80b71811c30/scratchpad/rt_probe.txt"
	assert(rt.writeFile(path, "hello").status == .Ok)
	rf := rt.readFile(path)
	assert(rf.status == .Ok && rf.value.content == "hello", "read back what was written")
	assert(rt.appendFile(path, " world").status == .Ok)
	rf2 := rt.readFile(path)
	assert(rf2.value.content == "hello world", "append")
	assert(rt.fileExists(path))
	assert(rt.removeFile(path).status == .Ok)
	assert(!rt.fileExists(path))
	missing := rt.readFile("/nonexistent/nope.txt")
	assert(missing.status == .Err && missing.err == rt.errCode("fs/FsError.NotFound"))
	assert(rt.removeFile("/nonexistent/nope.txt").err == rt.errCode("fs/FsError.NotFound"))

	// --- sys ---
	assert(rt.argCount().count >= 0)
	assert(rt.getEnv("PATH").status == .Ok, "PATH should be set")
	assert(rt.getEnv("TUCK_DEFINITELY_UNSET_VAR_XYZ").status == .Absent,
	       "unset env is absence, not error")

	// --- time ---
	t0 := rt.nowMs().ms
	rt.sleepMs(20)
	assert(rt.nowMs().ms >= t0 + 10, "clock advances across sleep")

	// --- str/seq ---
	assert(rt.tuckConcat("ab", "cd") == "abcd")
	items := []int{10, 20, 30}
	assert(rt.at(items, 1) == 20)

	fmt.println("OK - tuck_rt.odin: all externs + result contract verified")
	os.exit(0)
}
