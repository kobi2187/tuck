// compiler/tuckrt/tuck_rt.odin
//
// The Odin backend's runtime, mirroring compiler/tuck_rt.nim's contract:
// TuckResult (the !T/?T carrier), saturating arithmetic, bump arenas, object
// pools, mailboxes, and the stdlib externs std/*.tuck declares.
//
// Generated Odin imports this as `rt`, so every entry point here is what
// codegen_odin.nim emits as `rt.<name>`.
//
// Actors each get an OS thread (tuck_coro.odin), so the mailbox IS locked —
// see MailboxLock there. Tasks remain coroutines on main's thread.
package tuckrt

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "base:intrinsics"
import "core:mem"
import "core:strings"
import "core:sys/linux"
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

// A heap copy of a str the caller will own. Emitted where the ownership
// pass needs a LITERAL to be freeable: a local that frees its old value at
// each overwrite cannot start from static storage (analysis_ownership, step 5).
tuckStrOwned :: proc(s: string) -> string {
	return strings.clone(s)
}

toStr :: proc(value: $T) -> string {
	// cstring is a bare char* from C: aprint would format the POINTER, not
	// the text. Odin's string(cstr) walks to the NUL and copies, which is
	// what crossing the FFI boundary into a Tuck string has to mean.
	when T == cstring {
		return strings.clone(string(value))
	} else {
		return fmt.aprint(value)
	}
}

tuckConcat :: proc(a, b: string) -> string {
	return strings.concatenate({a, b})
}

// Bit operations. Tuck has no bitwise OPERATORS — `|` is already sum-variant
// syntax and a word operator is refused (TK-PA11) — so these are ordinary
// postfix calls declared in std/bits.tuck, the same shape std/seq.tuck uses
// for at/setAt. Everything that wants bits is written against them.
bitAnd :: proc(a, b: u64) -> u64 { return a & b }
bitOr :: proc(a, b: u64) -> u64 { return a | b }
bitXor :: proc(a, b: u64) -> u64 { return a ~ b }
bitNot :: proc(a: u64) -> u64 { return ~a }

// A shift at or past the width is 0, not undefined — C leaves `x << 64`
// undefined and each backend inherits that, so the guard lives here.
shiftLeft :: proc(a: u64, by: int) -> u64 {
	if by >= 64 || by < 0 { return 0 }
	return a << u64(by)
}

shiftRight :: proc(a: u64, by: int) -> u64 {
	if by >= 64 || by < 0 { return 0 }
	return a >> u64(by)
}

// seq access. Bounds are a PRECONDITION: violating one is a program error,
// not an error value the caller matches.
// `xs[i]` bracket sugar lowers to tuckAt/tuckSetAt, NOT to std/seq's
// `at` — brackets are grammar, so they must work without `import seq`,
// and the reserved `tuck` prefix keeps them clear of a user's own `at`.
// std/seq.tuck's `at`/`setAt` stay as the explicit spelling, delegating.
// Each comes in a SLICE and a DYNAMIC form, grouped. Tuck's `Seq[T]` emits as
// `[dynamic]T`, and while Odin converts a dynamic array to a slice implicitly
// in an ordinary call, it will NOT do so while inferring `$T` — `xs[0]` on a
// Seq field reported "Cannot determine polymorphic type from parameter:
// '[dynamic]int' to '[]$T'". So reading a Seq by index did not compile on this
// backend at all; nothing in the corpus indexed one.
// A Tuck `Seq` assignment COPIES. Odin's `[dynamic]T` assignment copies the
// HEADER, so both names then view one buffer and `b[0] = 99` writes `a[0]`.
// Verified divergent: the same program exits 1 on Nim and D and 99 here.
// lowering_seqcopy marks the sites; this is what the emitter prints there.
//
// Bulk, not element-by-element. This copied with `reserve` + an `append` per
// element — a call and a capacity check per item, where the whole point is
// one contiguous move.
//
// The win it is worth TODAY is modest, and the reason is worth writing down.
// Measured on 200_000 copies of a 1024-element ladder (the matching engine's
// real shape):
//
//   copies freed, one block reused : append 198ms, bulk 49ms   -> 4.1x
//   copies never freed (EV-12)     : append 245ms, bulk 195ms  -> 1.26x
//
// Nothing here frees, so every copy is a fresh page-faulting allocation and
// the ALLOCATOR dominates, not the copy loop. On the matching engine that
// shows up as roughly 10%, not 4x. The full win is gated behind EV-12: fix
// the leak so memory is reused, and the copy method becomes the cost that
// matters. The two are multiplicative, which is also the order to do them
// in.
// --- allocation tracking, for proving a free is right ------------------------
//
// This backend has no collector, so every heap value it copies is live until
// the process exits (KNOWN-BUGS-EVENTS.md EV-12, issue #77). Inserting frees
// is the fix, and the failure mode of getting one wrong is a use-after-free
// or a double free — silent, and far worse than the leak it replaces.
//
// So the frees get a harness before they get written. `-define:TUCK_TRACK=true`
// routes every allocation through Odin's tracking allocator and prints, at
// exit, what leaked AND what was freed wrongly. Off by default: it costs a
// map insert per allocation, which is exactly the thing being measured.
//
// The report is called EXPLICITLY from the entry point rather than deferred.
// `os.exit` is `_exit` — it runs no defers and no finalizers, which is the
// same reason the resource registry closes its tables by hand there.
TUCK_TRACK :: #config(TUCK_TRACK, false)

when TUCK_TRACK {
	gTrack: mem.Tracking_Allocator
	gTrackReady: bool
}

tuckTrackAllocator :: proc() -> mem.Allocator {
	// RETURNS the allocator rather than installing it, because Odin's
	// `context` is an implicit per-proc copy: assigning `context.allocator`
	// in here would rebind this proc's context and nothing else. The entry
	// point assigns what this hands back, which is the only place the
	// assignment reaches the rest of the program.
	//
	// With tracking off it hands back the context's own allocator, so the
	// emitted line is unconditional and no `when` leaks into generated code.
	when TUCK_TRACK {
		// ONCE. Every actor thread calls this too — it gets a fresh context
		// and would otherwise re-init the tracker, wiping what main and the
		// other threads had recorded. No lock is needed because the entry
		// point calls this on its first line, before any actor exists.
		if !gTrackReady {
			mem.tracking_allocator_init(&gTrack, context.allocator)
			// A bad free PANICS by default, which is the right loudness for
			// the mistake this exists to catch — but the panic would pre-empt
			// the report, so it is downgraded to recording and the exit code
			// carries the verdict instead.
			gTrack.bad_free_callback = nil
			gTrackReady = true
		}
		return mem.tracking_allocator(&gTrack)
	} else {
		return context.allocator
	}
}

tuckTrackCheck :: proc() {
	// EXITS here rather than handing a count back for the entry point to act
	// on. The emitted call must not mention `os`: Odin errors on an unused
	// import, so the generated header carries `core:os` only when the program
	// itself needed it — and a `fn main() -> void` does not. Emitting
	// `os.exit(90)` made every such program fail to compile.
	if tuckTrackReport() > 0 { os.exit(90) }
}

tuckTrackReport :: proc() -> int {
	// Returns the number of faults, so a test can assert on an exit code
	// rather than parse output.
	when TUCK_TRACK {
		faults := 0
		if len(gTrack.allocation_map) > 0 {
			total := 0
			for _, entry in gTrack.allocation_map { total += entry.size }
			fmt.eprintf("TUCK-ALLOC leaked %v allocation(s), %v bytes (peak %v)\n",
			            len(gTrack.allocation_map), total,
			            gTrack.peak_memory_allocated)
			faults += len(gTrack.allocation_map)
		}
		// A bad free is the failure mode that matters: it means an emitted
		// `delete` reached memory that was not ours, or was already gone.
		if len(gTrack.bad_free_array) > 0 {
			fmt.eprintf("TUCK-ALLOC %v BAD FREE(S) - a delete was wrong\n",
			            len(gTrack.bad_free_array))
			for bf in gTrack.bad_free_array {
				fmt.eprintf("  bad free of %v at %v\n", bf.memory, bf.location)
			}
			faults += len(gTrack.bad_free_array)
		}
		return faults
	} else {
		return 0
	}
}

tuckSeqCopy :: proc(items: [dynamic]$T) -> [dynamic]T {
	out: [dynamic]T
	if len(items) == 0 { return out }
	resize(&out, len(items))
	copy(out[:], items[:])
	return out
}

tuckAt_slice :: proc(items: []$T, index: int) -> T {
	assert(index >= 0 && index < len(items), "at: index out of bounds")
	return items[index]
}

tuckAt_dyn :: proc(items: [dynamic]$T, index: int) -> T {
	return tuckAt_slice(items[:], index)
}

tuckAt :: proc{tuckAt_slice, tuckAt_dyn}

at :: proc{tuckAt_slice, tuckAt_dyn}

tuckSetAt_slice :: proc(items: []$T, index: int, value: T) {
	assert(index >= 0 && index < len(items), "setAt: index out of bounds")
	items[index] = value
}

tuckSetAt_dyn :: proc(items: [dynamic]$T, index: int, value: T) {
	tuckSetAt_slice(items[:], index, value)
}

tuckSetAt :: proc{tuckSetAt_slice, tuckSetAt_dyn}

setAt :: proc{tuckSetAt_slice, tuckSetAt_dyn}

// `Array[N, T]` needs its OWN pair, separate from tuckAt/tuckSetAt above.
// core.array's `at`/`setAt` cannot be plain Tuck functions using `items[i]`:
// the bracket-index dispatch routes to whatever `fn at` is in scope, which —
// inside `at`'s OWN body — is `at` itself. A Tuck-body `at` for Array[N, T]
// self-recurses infinitely rather than indexing. std/seq.tuck's `at`/`setAt`
// dodge this because THIS proc, not a Tuck fn, is what the bracket actually
// lowers to; core.array's `at`/`setAt` must be `extern` declarations bound
// to these, with no Tuck body to recurse in — same shape, one container over.
tuckArrayAt :: proc(items: [$N]$T, index: int) -> T {
	assert(index >= 0 && index < N, "at: index out of bounds")
	return items[index]
}

tuckArraySetAt :: proc(items: ^[$N]$T, index: int, value: T) {
	assert(index >= 0 && index < N, "setAt: index out of bounds")
	items[index] = value
}

// Value semantics: allocates its own backing array rather than growing
// `items` in place, so `items`'s own backing store is never shared with
// (and never mutated through) the result — a plain-value append on a
// [dynamic]T copy would still share the source memory below capacity.
getLength :: proc(x: $T) -> int { return len(x) }

count :: proc(items: [dynamic]$T) -> int { return len(items) }

byteCount :: proc(t: string) -> int { return len(t) }

fromBytes :: proc(bytes: [dynamic]u8) -> string {
	return strings.clone_from_bytes(bytes[:])
}

byteAt :: proc(t: string, index: int) -> u8 {
	assert(index >= 0 && index < len(t), "byteAt: index out of bounds")
	return t[index]
}

parseFloat :: proc(t: string) -> TuckResult(f64) {
	// Absent, not an error: "that text is not a number" has a legitimate no.
	v, ok := strconv.parse_f64(t)
	if !ok { return tnone(f64) }
	return tok(v)
}

joinStr :: proc(parts: [dynamic]string, sep: string) -> string {
	// One pass — `acc = concat(acc, part)` in a loop is O(n^2).
	return strings.join(parts[:], sep)
}

push :: proc(items: [dynamic]$T, value: T) -> [dynamic]T {
	result := make([dynamic]T, len(items))
	copy(result[:], items[:])
	append(&result, value)
	return result
}

charAt :: proc(s: string, index: int) -> string {
	assert(index >= 0 && index < len(s), "charAt: index out of bounds")
	return strings.clone(string([]u8{s[index]}))
}

containsChar :: proc(s: string, ch: string) -> bool {
	return strings.contains(s, ch)
}

splitLines :: proc(s: string) -> [dynamic]string {
	lines, _ := strings.split_lines(s)
	result := make([dynamic]string, len(lines))
	copy(result[:], lines[:])
	return result
}

ord :: proc(ch: string) -> int {
	assert(len(ch) > 0, "ord: index 0 out of bounds for seq of length 0")
	return int(ch[0])
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

// std/math — elementary float functions, direct passthroughs to core:math.
sqrt :: proc(value: f64) -> f64 {
	return math.sqrt(value)
}

pow :: proc(base, exp: f64) -> f64 {
	return math.pow(base, exp)
}

// std/hash — FNV-1a, 64-bit. Same algorithm as errCode above (32-bit,
// compile-time-oriented); this is the runtime, arbitrary-length variant.
hash :: proc(data: string) -> u64 {
	h: u64 = 14695981039346656037
	for c in transmute([]u8)data {
		h = (h ~ u64(c)) * 1099511628211
	}
	return h
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
// What `acquire` hands back: WHICH cell, and WHICH TENANCY of it. The value
// used to be the cell's contents, so the cell's identity was gone by the time
// `release` needed it — it matched by equality, every slot held the same zero
// value, and every release freed slot 0. Same shape in all three runtimes.
// ---------------------------------------------------------------------------
// spec 7.4: the resource registry. The Odin twin of tuck_rt.nim's — same
// structure, same policies, same LIFO close-all. See the Nim copy for why
// each piece is shaped the way it is; this file states the Odin spelling.

ResourceHandle :: struct {
	slot: i32,
	gen:  u32,
}

RtResourcePolicy :: enum u8 {
	Strict, // close at the mark. Deterministic; the embedded/debug default
	Lazy,   // mark only; the inline watermark sweep reclaims
	Exit,   // close-all at program end
}

RtOnFull :: enum u8 {
	Absent, // report absence; the caller decides (the default)
	Error,  // abort, naming the kind and its cap
}

// How THIS kind's OS handle is released. A callback because the runtime
// cannot know: an fd, an mmap and a TLS session are three different syscalls.
ResourceCloser :: #type proc(reference: i64)

// spec 7.4's `on_finish` vocabulary, as real syscalls on the reference. The
// declaration PICKS one and the emitted table binds it, so there is one
// mechanism — setResourceHooks overrides the same field, which is the escape
// hatch for a kind whose reference is not an fd at all.
//
// A failed syscall is deliberately not reported: on_finish runs at the MARK,
// where the program has already said it is done with the handle.
tuckResFlush :: proc(reference: i64) {
	linux.fsync(linux.Fd(reference))
}

tuckResShutdown :: proc(reference: i64) {
	linux.shutdown(linux.Fd(reference), .RDWR)
}

ResourceEntry :: struct {
	reference: i64,    // the OS handle: an fd, or a pointer cast to int
	gen:       u32,    // tenancy; bumped at the MARK, so the handle dies there
	live:      bool,   // this slot is occupied at all
	finished:  bool,   // marked; awaiting reclamation. Only these are evicted
	site:      string, // where it was acquired — the report's whole value
}

ResourceTable :: struct {
	kind:          string,
	cap:           int, // 0 = unbounded (dynamic); >0 = the bound
	policy:        RtResourcePolicy,
	onFull:        RtOnFull, // only consulted when `cap` > 0
	sweepBatch:    int, // 0 = evict every finished entry; >0 = that many
	onFinish:      ResourceCloser, // runs at the MARK, always (file: flush)
	onClose:       ResourceCloser, // runs at reclamation
	entries:       [dynamic]ResourceEntry,
	order:         [dynamic]i32, // registration order; close-all walks it back
	finishedCount: int,
}

tuckResourceMisuse :: proc(table: string, what: string) {
	// Aborts rather than returning, for the reason tuckPoolMisuse does: a
	// stale handle that writes to a REUSED slot is the bug 7.4 exists to
	// make impossible.
	fmt.eprintln("TUCK RESOURCE [", table, "]: ", what, sep = "")
	os.exit(1)
}

initResourceTable :: proc(t: ^ResourceTable, kind: string, cap: int,
                          policy: RtResourcePolicy, sweepBatch: int,
                          onFull: RtOnFull = .Absent) {
	t.kind = kind
	t.cap = cap
	t.policy = policy
	t.sweepBatch = sweepBatch
	t.onFull = onFull
	if cap > 0 && len(t.entries) < cap {
		// A capped kind is array-shaped from the start: the cap is a
		// LINK-TIME memory budget, not a limit discovered at runtime.
		resize(&t.entries, cap)
	}
}

setResourceHooks :: proc(t: ^ResourceTable, onFinish, onClose: ResourceCloser) {
	t.onFinish = onFinish
	t.onClose = onClose
}

@(private)
rtReclaim :: proc(t: ^ResourceTable, i: int) {
	// Never called on a LIVE entry: 7.4 has no time-based eviction, and an
	// entry nobody finished is still in use by definition.
	if !t.entries[i].live || !t.entries[i].finished { return }
	if t.onClose != nil { t.onClose(t.entries[i].reference) }
	t.entries[i].live = false
	t.entries[i].site = ""
	t.finishedCount -= 1
	for k in 0 ..< len(t.order) {
		if t.order[k] == i32(i) {
			ordered_remove(&t.order, k)
			break
		}
	}
}

sweep :: proc(t: ^ResourceTable) -> int {
	// Also the `kind::sweep` an explicit scheduled cleanup calls — the inline
	// trigger and the explicit one are one proc, so a program that sweeps by
	// hand and one that lets the marks do it cannot drift apart.
	taken := 0
	limit := t.sweepBatch if t.sweepBatch > 0 else len(t.entries)
	for i in 0 ..< len(t.entries) {
		if taken >= limit { break }
		if t.entries[i].live && t.entries[i].finished {
			rtReclaim(t, i)
			taken += 1
		}
	}
	return taken
}

@(private)
rtWatermarkReached :: proc(t: ^ResourceTable) -> bool {
	// ~75% of cap. An uncapped table has no watermark: its bound is the OS
	// ulimit, and there is no budget to measure against.
	return t.cap > 0 && (t.finishedCount * 4) >= (t.cap * 3)
}

acquireResource :: proc(t: ^ResourceTable, reference: i64,
                        site: string) -> TuckResult(ResourceHandle) {
	// Exhaustion is ABSENCE, not an error — the caller decides what running
	// out means, exactly as 7.2's pool does.
	//
	// Sizes a capped table on first use, so a table built as a plain literal
	// behaves exactly as one built through initResourceTable — which is what
	// lets the backend emit the declaration with no start-up code at all.
	if t.cap > 0 && len(t.entries) < t.cap { resize(&t.entries, t.cap) }
	for i in 0 ..< len(t.entries) {
		if t.entries[i].live { continue }
		t.entries[i].gen += 1
		t.entries[i].reference = reference
		t.entries[i].live = true
		t.entries[i].finished = false
		t.entries[i].site = site
		append(&t.order, i32(i))
		return tok(ResourceHandle{slot = i32(i), gen = t.entries[i].gen})
	}
	if t.cap > 0 {
		// The cap is the leak alarm as much as the budget: a table that FILLS
		// is a bug surfacing early rather than an OOM three days in. Which of
		// those two readings applies is the kind's own `on_full`.
		if t.onFull == .Error {
			tuckResourceMisuse(t.kind, "table is full and the kind declares `on_full: error`")
		}
		return tnone(ResourceHandle)
	}
	append(&t.entries, ResourceEntry{reference = reference, gen = 1,
	                                 live = true, site = site})
	append(&t.order, i32(len(t.entries) - 1))
	return tok(ResourceHandle{slot = i32(len(t.entries) - 1), gen = 1})
}

@(private)
rtEntryFor :: proc(t: ^ResourceTable, h: ResourceHandle, what: string) -> int {
	// Every way of being wrong is caught rather than absorbed: out of range,
	// never handed out, and — the one that matters — a generation that has
	// moved on, which is a handle held past its finish.
	//
	// `what` names the OPERATION, and the message says which slot and which
	// tenancies — that is the whole diagnosis: which handle, and how far the
	// slot has moved on since. Worded exactly as the Nim runtime words it, so
	// one program reports one thing whichever backend built it.
	i := int(h.slot)
	if i < 0 || i >= len(t.entries) {
		tuckResourceMisuse(t.kind,
			fmt.tprintf("%s of a handle that names no slot (%d)", what, i))
	} else if !t.entries[i].live {
		tuckResourceMisuse(t.kind,
			fmt.tprintf("%s of slot %d, which nobody holds", what, i))
	} else if t.entries[i].gen != h.gen {
		tuckResourceMisuse(t.kind,
			fmt.tprintf("%s of a stale handle for slot %d: tenancy %d, slot is on %d",
				what, i, h.gen, t.entries[i].gen))
	}
	return i
}

derefResource :: proc(t: ^ResourceTable, h: ResourceHandle) -> i64 {
	// The only way to reach the OS handle, which is what makes the generation
	// check unavoidable rather than something a caller can forget.
	return t.entries[rtEntryFor(t, h, "use")].reference
}

finishResource :: proc(t: ^ResourceTable, h: ResourceHandle) {
	// 7.4's mark: release INTENT, not necessarily release. on_finish runs,
	// the entry is marked, and the generation bumps — under every policy, so
	// the handle dies AT THE MARK. Only reclamation is policy, which is what
	// makes durability independent of sweep timing.
	i := rtEntryFor(t, h, "finish")
	if t.onFinish != nil { t.onFinish(t.entries[i].reference) }
	t.entries[i].finished = true
	t.entries[i].gen += 1
	t.finishedCount += 1
	switch t.policy {
	case .Strict:
		rtReclaim(t, i)
	case .Lazy:
		// Sweeping is INLINE — no thread, no background actor. The trigger
		// lives in the mark itself, so a loop acquiring ten thousand times
		// against a cap in the thousands never blocks.
		if rtWatermarkReached(t) { sweep(t) }
	case .Exit:
	}
}

closeAllResources :: proc(t: ^ResourceTable) {
	// LIFO in REGISTRATION order: files flush before the directories holding
	// them close, a TLS session shuts down before the socket under it.
	for k := len(t.order) - 1; k >= 0; k -= 1 {
		i := int(t.order[k])
		if !t.entries[i].live { continue }
		if !t.entries[i].finished && t.onFinish != nil {
			t.onFinish(t.entries[i].reference)
		}
		if t.onClose != nil { t.onClose(t.entries[i].reference) }
		t.entries[i].live = false
		t.entries[i].finished = false
		t.entries[i].site = ""
	}
	clear(&t.order)
	t.finishedCount = 0
}

openResourceCount :: proc(t: ^ResourceTable) -> int {
	n := 0
	for k in 0 ..< len(t.order) {
		i := int(t.order[k])
		if t.entries[i].live && !t.entries[i].finished { n += 1 }
	}
	return n
}

reportOpenResources :: proc(t: ^ResourceTable) {
	// 7.4's OPEN RESOURCES report. Debug builds only, and silent when there
	// is nothing to say — a report that prints "0" every run is one people
	// stop reading.
	when ODIN_DEBUG {
		n := openResourceCount(t)
		if n == 0 { return }
		fmt.eprintfln("OPEN RESOURCES [%s] (%d):", t.kind, n)
		for k in 0 ..< len(t.order) {
			i := int(t.order[k])
			if t.entries[i].live && !t.entries[i].finished {
				fmt.eprintfln("  slot %d acquired at %s", i, t.entries[i].site)
			}
		}
	}
}

shutdownResources :: proc(t: ^ResourceTable) {
	// SAY what leaked, then close everything — in that order, since close-all
	// empties the table and a report after it is always silent.
	reportOpenResources(t)
	closeAllResources(t)
}

PoolHandle :: struct {
	slot: i32,
	gen:  u32,
}

ObjectPool :: struct($T: typeid, $Count: int) {
	storage:  [Count]T,
	gen:      [Count]u32, // tenancy counter per cell; 0 = never handed out
	occupied: u64, // ponytail: 64 slots max; widen to an array if needed
}

tuckPoolMisuse :: proc(what: string) {
	// Aborts rather than returning: the alternative is the silent corruption
	// this replaced.
	fmt.eprintln("TUCK POOL:", what)
	os.exit(1)
}

acquire :: proc(pool: ^ObjectPool($T, $Count)) -> TuckResult(PoolHandle) {
	for i in 0 ..< Count {
		if (pool.occupied & (u64(1) << u64(i))) == 0 {
			pool.occupied |= u64(1) << u64(i)
			pool.gen[i] += 1
			return tok(PoolHandle{slot = i32(i), gen = pool.gen[i]})
		}
	}
	return tnone(PoolHandle)
}

release :: proc(pool: ^ObjectPool($T, $Count), h: PoolHandle) {
	// The handle names the cell, so there is nothing to search for. Every way
	// of being wrong is caught rather than absorbed.
	i := int(h.slot)
	if i < 0 || i >= Count {
		tuckPoolMisuse("release of a handle that names no slot")
	} else if (pool.occupied & (u64(1) << u64(i))) == 0 {
		tuckPoolMisuse("double release")
	} else if pool.gen[i] != h.gen {
		tuckPoolMisuse("release of a stale handle")
	} else {
		pool.occupied &~= u64(1) << u64(i)
	}
}

// A spinlock for the mailbox. NOT decoration: this runtime spawns one OS
// thread per actor (tuck_coro.odin's tuckStartActor), so a send from main and
// a drain on the actor's thread genuinely race. The mailbox carried NO
// synchronisation at all until 2026-09-20, and the comment here still claimed
// "single-threaded and cooperative" — true before thread-per-actor landed,
// false ever since, and nobody updated it (KNOWN-BUGS-EVENTS.md EV-5).
//
// A spinlock rather than a Mutex for the reason the Nim runtime measured: the
// section is a bounds check, one array write and an index bump, and a busy
// actor should find it free without paying a futex round trip.
MailboxLock :: struct {
	flag: bool,
}

mbLock :: proc(l: ^MailboxLock) {
	for intrinsics.atomic_exchange_explicit(&l.flag, true, .Acquire) {
		for intrinsics.atomic_load_explicit(&l.flag, .Relaxed) {
			intrinsics.cpu_relax()
		}
	}
}

mbUnlock :: proc(l: ^MailboxLock) {
	intrinsics.atomic_store_explicit(&l.flag, false, .Release)
}

// Actor mailbox: TWO buffers, not one ring. Senders fill buf[cur]; the actor
// flips `cur` and then owns the buffer it took outright, so the whole drain
// runs with no lock held and nothing copied out. A handover is one integer
// write whatever the batch size.
//
// Mirrors compiler/tuck_rt.nim. `[queue: N]` means "N messages may be waiting
// to be picked up", and an actor may hold up to another N it has taken.
Mailbox :: struct($T: typeid, $Cap: int) {
	buf:  [2][Cap]T,
	_pad: [64]u8,   // keeps the control block off the last cache line of the
	                // buffers: the actor streams one while senders hammer the
	                // lock, and sharing a line makes them invalidate each
	                // other for nothing
	fill: [2]int,
	cur:  int,
	lock: MailboxLock,
}

enqueue :: proc(mb: ^Mailbox($T, $Cap), msg: T) -> bool {
	mbLock(&mb.lock)
	c := mb.cur
	if mb.fill[c] >= Cap {
		mbUnlock(&mb.lock)
		return false // full: sendX drops (spec §9.1)
	}
	mb.buf[c][mb.fill[c]] = msg
	mb.fill[c] += 1
	mbUnlock(&mb.lock)
	return true
}

// Take everything waiting. The swap happens once, under the lock; the caller
// then walks `batch[:n]` with no lock held and nothing copied out. Odin has no
// iterator to hide this behind the way Nim and D do, so the emitted drain
// loops over the returned slice — the one place the three backends differ in
// shape rather than only in syntax.
//
// `fill` is cleared before returning rather than after the walk, so an early
// exit leaves the mailbox consistent instead of re-delivering a batch.
takeBatch :: proc(mb: ^Mailbox($T, $Cap)) -> (batch: []T, n: int) {
	mbLock(&mb.lock)
	c := mb.cur
	n = mb.fill[c]
	if n > 0 {
		mb.cur = 1 - c // THE SWAP: the actor now owns buf[c]
		mb.fill[c] = 0
	}
	mbUnlock(&mb.lock)
	return mb.buf[c][:], n
}

// Sender's opt-in backpressure check. sendX drops silently on a full mailbox
// (fast, non-blocking, spec §9.1) — the sender may check first if it cares.
hasRoom :: proc(mb: ^Mailbox($T, $Cap)) -> bool {
	mbLock(&mb.lock)
	r := mb.fill[mb.cur] < Cap
	mbUnlock(&mb.lock)
	return r
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

// std/net payloads
NetFd :: struct {
	fd: int,
}

NetData :: struct {
	data: string,
}

NetSent :: struct {
	sent: int,
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

// These all block: a regular file is always "ready" to epoll, so the reactor
// cannot await one. They run on the worker via tuckSubmitBlocking (see
// tuck_coro.odin), which parks the calling coroutine on a completion pipe.
//
// Mirrors tuck_rt.nim, but simpler: Odin has no GC, so the worker may use the
// ordinary allocator and the request can hold Odin strings and slices directly
// — the Nim side has to marshal through C buffers to keep the collector out of
// the worker's reach.

IoStatus :: enum {
	Ok,
	NotFound,
	IoFailed,
	AccessDenied,
	EndOfInput,
}

@(private)
FileOp :: enum {
	Read,
	Write,
	Append,
	Remove,
}

@(private)
FileReq :: struct {
	op:      FileOp,
	path:    string,
	data:    string,
	outData: []u8,
	status:  IoStatus,
}

@(private)
fileWorker :: proc(arg: rawptr) {
	r := (^FileReq)(arg)
	switch r.op {
	case .Read:
		if !os.exists(r.path) {
			r.status = .NotFound
			return
		}
		data, err := os.read_entire_file_from_path(r.path, context.allocator)
		if err != nil {
			r.status = .IoFailed
			return
		}
		r.outData = data
	case .Write:
		if os.write_entire_file(r.path, transmute([]u8)r.data) != nil {
			r.status = .AccessDenied
		}
	case .Append:
		f, err := os.open(r.path, os.O_WRONLY | os.O_APPEND | os.O_CREATE,
			os.Permissions{.Read_User, .Write_User, .Read_Group, .Read_Other})
		if err != nil {
			r.status = .AccessDenied
			return
		}
		defer os.close(f)
		if _, werr := os.write(f, transmute([]u8)r.data); werr != nil {
			r.status = .AccessDenied
		}
	case .Remove:
		if !os.exists(r.path) {
			r.status = .NotFound
			return
		}
		if os.remove(r.path) != nil do r.status = .AccessDenied
	}
}

@(private)
runFileOp :: proc(op: FileOp, path: string, data: string = "") -> FileReq {
	// The request lives on THIS coroutine's stack for the whole call: it cannot
	// proceed until the worker signals, so the worker's view is always valid.
	req := FileReq{op = op, path = path, data = data, status = .Ok}
	tuckSubmitBlocking(fileWorker, &req)
	return req
}

// One place mapping a worker outcome onto the FsError variants declared in
// std/fs.tuck. Exhaustive, so a new IoStatus is a compile error here rather
// than a silently wrong error code at four call sites.
@(private)
fsErrCode :: proc(s: IoStatus) -> u16 {
	switch s {
	case .NotFound:     return errCode("fs/FsError.NotFound")
	case .AccessDenied: return errCode("fs/FsError.AccessDenied")
	case .Ok, .IoFailed, .EndOfInput:
		return errCode("fs/FsError.IoFailed")
	}
	return errCode("fs/FsError.IoFailed")
}

readFile :: proc(path: string) -> TuckResult(FsContent) {
	r := runFileOp(.Read, path)
	if r.status != .Ok do return terr(FsContent, fsErrCode(r.status))
	return tok(FsContent{content = string(r.outData)})
}

writeFile :: proc(path: string, content: string) -> TuckResult(TuckUnit) {
	r := runFileOp(.Write, path, content)
	if r.status != .Ok do return terr(TuckUnit, fsErrCode(r.status))
	return tokVoid()
}

appendFile :: proc(path: string, content: string) -> TuckResult(TuckUnit) {
	r := runFileOp(.Append, path, content)
	if r.status != .Ok do return terr(TuckUnit, fsErrCode(r.status))
	return tokVoid()
}

removeFile :: proc(path: string) -> TuckResult(TuckUnit) {
	r := runFileOp(.Remove, path)
	if r.status != .Ok do return terr(TuckUnit, fsErrCode(r.status))
	return tokVoid()
}

// NOT offloaded: a stat is a metadata lookup, microseconds on any live
// filesystem. Paying a thread handoff and a pipe round-trip would cost more
// than the call. Mirrors the Nim side.
fileExists :: proc(path: string) -> bool {
	return os.exists(path)
}

// Idempotent by an explicit existence check, same as the Nim runtime, so
// all three backends agree on the same contract rather than relying on
// each platform's own already-exists behavior for mkdir -p.
makeDir :: proc(path: string) -> TuckResult(TuckUnit) {
	if os.exists(path) do return tokVoid()
	err := os.make_directory_all(path)
	if err != nil {
		if err == os.General_Error.Not_Exist {
			return terr(TuckUnit, errCode("fs/FsError.NotFound"))
		}
		return terr(TuckUnit, errCode("fs/FsError.IoFailed"))
	}
	return tokVoid()
}

// --- std/io ---

print :: proc(text: string) {
	fmt.print(text)
}

printLine :: proc(text: string) {
	fmt.println(text)
}

@(private)
ReadLineReq :: struct {
	buf:    [4096]u8,
	len:    int,
	status: IoStatus,
}

@(private)
readLineWorker :: proc(arg: rawptr) {
	r := (^ReadLineReq)(arg)
	n, err := os.read(os.stdin, r.buf[:])
	if err != nil {
		r.status = .IoFailed
		return
	}
	if n <= 0 {
		r.status = .EndOfInput
		return
	}
	r.len = n
}

// Blocks on user input, so it runs on the worker: waiting for it inline would
// stop every timer and actor in the process until someone hits enter.
//
// stdin DOES have real readiness, so this could reach the reactor instead —
// see thoughts/async-endgame-measurements.md. The worker was the fix that
// removed the hang; the reactor is the better implementation of the same
// extern, and applies to both backends equally.
readLine :: proc() -> TuckResult(IoLine) {
	req := ReadLineReq{status = .Ok}
	tuckSubmitBlocking(readLineWorker, &req)
	switch req.status {
	case .EndOfInput:
		return terr(IoLine, errCode("console/IoError.EndOfInput"))
	case .Ok:
		line := strings.trim_right(string(req.buf[:req.len]), "\r\n")
		return tok(IoLine{line = strings.clone(line)})
	case .IoFailed, .NotFound, .AccessDenied:
		return terr(IoLine, errCode("console/IoError.IoFailed"))
	}
	return terr(IoLine, errCode("console/IoError.IoFailed"))
}

// --- std/net: TCP over the reactor ------------------------------------------
//
// Sockets have real readiness, so every one of these SUSPENDS the calling task
// through the reactor rather than blocking the process. None touch the
// blocking worker — that is only for files, path metadata and DNS, which have
// no readiness to await. Mirrors tuck_rt.nim.

NetErrKind :: enum {
	Refused,
	AddressInUse,
	Unreachable,
	Closed,
	IoFailed,
}

@(private)
netErrCode :: proc(e: NetErrKind) -> u16 {
	switch e {
	case .Refused:      return errCode("net/NetError.Refused")
	case .AddressInUse: return errCode("net/NetError.AddressInUse")
	case .Unreachable:  return errCode("net/NetError.Unreachable")
	case .Closed:       return errCode("net/NetError.Closed")
	case .IoFailed:     return errCode("net/NetError.IoFailed")
	}
	return errCode("net/NetError.IoFailed")
}

@(private)
classifyErrno :: proc(e: linux.Errno) -> NetErrKind {
	#partial switch e {
	case .ECONNREFUSED: return .Refused
	case .EADDRINUSE:   return .AddressInUse
	case .ENETUNREACH, .EHOSTUNREACH: return .Unreachable
	case .EPIPE, .ECONNRESET: return .Closed
	}
	return .IoFailed
}

@(private)
parseIPv4 :: proc(host: string) -> (addr: [4]u8, ok: bool) {
	// Dotted quad only. A hostname needs DNS, which blocks and therefore
	// belongs on the worker — not wired yet, so say so rather than connecting
	// somewhere unintended.
	parts := strings.split(host, ".", context.temp_allocator)
	if len(parts) != 4 do return {}, false
	for p, i in parts {
		v := 0
		if len(p) == 0 do return {}, false
		for ch in p {
			if ch < '0' || ch > '9' do return {}, false
			v = v * 10 + int(ch - '0')
		}
		if v > 255 do return {}, false
		addr[i] = u8(v)
	}
	return addr, true
}

listen :: proc(port: int) -> TuckResult(NetFd) {
	fd, err := linux.socket(.INET, .STREAM, {.NONBLOCK}, .TCP)
	if err != .NONE do return terr(NetFd, netErrCode(classifyErrno(err)))
	// SO_REUSEADDR so a restarted server does not trip over its own TIME_WAIT
	// sockets — without it, rebinding within ~60s of a shutdown fails.
	yes: b32 = true
	_ = linux.setsockopt(fd, linux.SOL_SOCKET, linux.Socket_Option.REUSEADDR, &yes)
	sa := linux.Sock_Addr_In{
		sin_family = .INET,
		sin_port   = u16be(u16(port)),
		sin_addr   = {0, 0, 0, 0},
	}
	if berr := linux.bind(fd, &sa); berr != .NONE {
		k := classifyErrno(berr)
		linux.close(fd)
		return terr(NetFd, netErrCode(k))
	}
	if lerr := linux.listen(fd, 64); lerr != .NONE {
		k := classifyErrno(lerr)
		linux.close(fd)
		return terr(NetFd, netErrCode(k))
	}
	return tok(NetFd{fd = int(fd)})
}

accept :: proc(fd: int) -> TuckResult(NetFd) {
	// Suspends on the listening fd until a client arrives. Re-parks on a
	// spurious wake (another coroutine took the connection first).
	for {
		tuckAwaitRead(fd)
		sa: linux.Sock_Addr_In
		c, err := linux.accept(linux.Fd(fd), &sa, {.NONBLOCK})
		if err == .NONE do return tok(NetFd{fd = int(c)})
		if err != .EAGAIN do return terr(NetFd, netErrCode(classifyErrno(err)))
	}
}

connect :: proc(host: string, port: int) -> TuckResult(NetFd) {
	// Non-blocking connect: the syscall returns EINPROGRESS immediately and
	// the fd becomes WRITABLE when the handshake finishes, so the task
	// suspends on write-readiness rather than blocking.
	ip, okIp := parseIPv4(host)
	if !okIp do return terr(NetFd, netErrCode(.Unreachable))
	fd, err := linux.socket(.INET, .STREAM, {.NONBLOCK}, .TCP)
	if err != .NONE do return terr(NetFd, netErrCode(classifyErrno(err)))
	sa := linux.Sock_Addr_In{
		sin_family = .INET,
		sin_port   = u16be(u16(port)),
		sin_addr   = ip,
	}
	cerr := linux.connect(fd, &sa)
	if cerr != .NONE && cerr != .EINPROGRESS {
		k := classifyErrno(cerr)
		linux.close(fd)
		return terr(NetFd, netErrCode(k))
	}
	if cerr == .EINPROGRESS {
		tuckAwaitWrite(int(fd))
		// The handshake's real outcome lands in SO_ERROR, not in connect's
		// return value.
		soErr: i32 = 0
		// getsockopt_base, not the getsockopt group: in Odin dev-2026-07 the
		// getsockopt_sock wrapper passes `cast(int) opt` into a parameter
		// declared `opt: Socket_Option` (core/sys/linux/sys.odin:751), so the
		// group fails to instantiate. Upstream bug, not ours.
		_, gerr := linux.getsockopt_base(fd, int(linux.SOL_SOCKET),
			linux.Socket_Option.ERROR, &soErr)
		if gerr == .NONE && soErr != 0 {
			linux.close(fd)
			return terr(NetFd, netErrCode(classifyErrno(linux.Errno(soErr))))
		}
	}
	return tok(NetFd{fd = int(fd)})
}

recv :: proc(fd: int, max: int) -> TuckResult(NetData) {
	// An EMPTY result means the peer closed cleanly — not an error, so callers
	// test `.data` for emptiness rather than matching a variant.
	if max <= 0 do return tok(NetData{data = ""})
	buf := make([]u8, max, context.allocator)
	for {
		tuckAwaitRead(fd)
		n, err := linux.recv(linux.Fd(fd), buf[:], {})
		if err == .NONE {
			if n == 0 do return tok(NetData{data = ""})
			return tok(NetData{data = strings.clone(string(buf[:n]))})
		}
		if err != .EAGAIN do return terr(NetData, netErrCode(classifyErrno(err)))
	}
}

send :: proc(fd: int, data: string) -> TuckResult(NetSent) {
	// Sends ALL of it, suspending on write-readiness whenever the kernel
	// buffer fills. A partial write is not surfaced: the caller asked to send
	// a value.
	if len(data) == 0 do return tok(NetSent{sent = 0})
	bytes := transmute([]u8)data
	sent := 0
	for sent < len(bytes) {
		n, err := linux.send(linux.Fd(fd), bytes[sent:], {})
		if err == .NONE {
			sent += n
		} else if err == .EAGAIN {
			tuckAwaitWrite(fd)
		} else {
			return terr(NetSent, netErrCode(classifyErrno(err)))
		}
	}
	return tok(NetSent{sent = sent})
}

close :: proc(fd: int) {
	linux.close(linux.Fd(fd))
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

// The reactor's timer, NOT the worker and NOT time.sleep. A sleep is the one
// "blocking" op that was never blocking-by-nature: waiting for a deadline is
// exactly what a timerfd does, so tuckSleep suspends only this coroutine while
// everything else keeps running. Offloading it would burn a thread to
// reproduce what the reactor already does for free.
//
// time.sleep here used to halt the process: the scheduler, the reactor, every
// actor and every timer, for the full duration.
sleepMs :: proc(ms: u32) {
	if activeCoroutine != nil {
		tuckSleep(int(ms))
	} else {
		time.sleep(time.Duration(ms) * time.Millisecond)   // no scheduler to yield to
	}
}
