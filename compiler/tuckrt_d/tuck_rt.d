// compiler/tuckrt_d/tuck_rt.d
//
// The Tuck runtime for the D backend — the counterpart of tuck_rt.nim (Nim)
// and tuckrt/tuck_rt.odin (Odin). Copied beside the emitted .d files by
// `tuck c --dlang`; emitted code reaches it as `import rt = tuck_rt;`.
//
// Grown lazily: a helper exists here only once emitted code actually calls
// it. Semantics must match tuck_rt.nim exactly — where D offers a native
// construct with identical behaviour (templates over $-stringification,
// writeln), it is used; where semantics would drift, the Nim shape is ported.
module tuck_rt;

import std.stdio : stdout;
import std.conv : text, to;
import std.array : join;
import core.sys.posix.unistd : pipe2, read, write, close;
import core.atomic : cas, atomicLoad, atomicStore;

// The coroutine engine is a separate file but the SAME facade: emitted code
// reaches everything through `rt`, so tuck_rt re-exports it — mirroring
// tuck_rt.nim, which fronts tuck_async the same way.
public import tuck_coro;

// std/console — terminal I/O (rt-implemented externs).
void print(string s) { stdout.write(s); stdout.flush(); }
void printLine(string s) { stdout.writeln(s); }

// `toStr` — the universal stringifier. tuck_rt.nim spells it `$value`; D's
// std.conv.text is the same "any value to its display form" operation.
string toStr(T)(T value) { return text(value); }

// !T is a result, ?T is an option: absence is a first-class state, not a
// reserved error code. !T uses Ok/Err, ?T uses Ok/Absent, !?T may be any.
//
// A VALUE carrier, deliberately — not a D exception. Tuck's `raise` returns
// a value and `expr?` inspects a status; exceptions unwind non-locally,
// which is a different semantic, so the identical-construct rule does not
// reach them here. Same three fields as tuck_rt.nim and tuck_rt.odin.
enum TuckStatus : ubyte
{
    Ok,
    Err,
    Absent,
}

/// Payload for a fn returning `!void` — a struct with no fields, matching
/// Odin's TuckUnit and Nim's `tuple[]`.
struct TuckUnit {}

struct TuckResult(T)
{
    TuckStatus status;
    ushort err;   /// app-wide error code; meaningful only when status == Err
    T value;
}

bool ok(T)(TuckResult!T r) { return r.status == TuckStatus.Ok; }

TuckResult!T tok(T)(T v)
{
    return TuckResult!T(TuckStatus.Ok, 0, v);
}

TuckResult!TuckUnit tokVoid()
{
    return TuckResult!TuckUnit(TuckStatus.Ok);
}

TuckResult!T terr(T)(ushort code)
{
    TuckResult!T r;
    r.status = TuckStatus.Err;
    r.err = code;
    return r;
}

TuckResult!T tnone(T)()
{
    TuckResult!T r;
    r.status = TuckStatus.Absent;
    return r;
}

/// `?` propagation: forward failure OR absence unchanged (status-preserving).
TuckResult!T tfwd(T)(TuckStatus status, ushort err)
{
    TuckResult!T r;
    r.status = status;
    r.err = err;
    return r;
}

/// `[saturating]` (spec 4.1): clamp at the type's bounds instead of
/// wrapping. The caller widens first, so the guard tests the real value
/// rather than one that has already wrapped.
T tuckSat(T)(ulong v) if (__traits(isUnsigned, T))
{
    return v > cast(ulong) T.max ? T.max : cast(T) v;
}

T tuckSatI(T)(long v) if (!__traits(isUnsigned, T))
{
    if (v > cast(long) T.max) return T.max;
    if (v < cast(long) T.min) return T.min;
    return cast(T) v;
}

/// An invariant violation (spec 4.7) — stop, naming the condition.
///
/// NOT `assert`: dmd's `-release` strips asserts outright, so a guard built
/// on one silently evaporates in exactly the build where a violated
/// invariant means corrupt data. ROADMAP's 2026-08-25 ruling 5 says
/// invariants stay on in release by default, opt-out only, so the check has
/// to be real code the optimiser keeps.
///
/// exit(1), NOT abort(): the same end as Nim's quit(1) and Odin's
/// os.exit(1), as tuckPoolMisuse and tuckResourceMisuse do (issue #54).
/// abort() raised SIGABRT (exit 134) where the other two exit 1 (#43).
void tuckInvariantFailed(string cond, string typeName)
{
    import std.stdio : stderr;
    import core.stdc.stdlib : exit;
    stderr.writeln("Invariant violated on ", typeName, ": ", cond);
    exit(1);
}

void tuckReportUnhandled(ushort code, string site)
{
    import std.stdio : stderr;
    stderr.writeln("TUCK UNHANDLED: error ", code, " at ", site);
}

/// Same FNV-1a fold as tuck_rt.nim's errCode, tuck_rt.odin's, and the
/// emitter's odinErrCode: stable across builds AND across backends.
ushort errCode(string name)
{
    uint h = 2166136261;
    foreach (char c; name)
        h = (h ^ cast(uint) c) * 16777619;
    return cast(ushort)((h ^ (h >> 16)) & 0xFFFF);
}

// std/math — elementary float functions, direct passthroughs to std.math.
double sqrt(double value)
{
    import std.math : stdSqrt = sqrt;
    return stdSqrt(value);
}

double pow(double base, double exp)
{
    import std.math : stdPow = pow;
    return stdPow(base, exp);
}

// std/hash — FNV-1a, 64-bit. Same algorithm as errCode above (32-bit);
// this is the runtime, arbitrary-length variant.
ulong hash(string data)
{
    ulong h = 14695981039346656037UL;
    foreach (char c; data)
        h = (h ^ cast(ulong) c) * 1099511628211UL;
    return h;
}

// seq access. Bounds are a PRECONDITION: violating one is a program error
// that aborts with the site, not an error value (mirrors tuck_rt.nim's
// IndexDefect; D's own bounds check would say the same thing, but this
// keeps the message and the op name identical across backends).
private void tuckSeqBounds(long index, long length, string op)
{
    import core.stdc.stdlib : abort;
    import std.stdio : stderr;
    if (index < 0 || index >= length)
    {
        stderr.writeln(op, ": index ", index,
                       " out of bounds for seq of length ", length);
        abort();
    }
}

/// `xs[i]` bracket sugar lowers to tuckAt/tuckSetAt, NOT to std/seq's
/// `at` — brackets are grammar, so they must work without `import seq`,
/// and the reserved `tuck` prefix keeps them clear of a user's own `at`.
/// std/seq.tuck's `at`/`setAt` stay as the explicit spelling, delegating.
T tuckAt(T)(T[] items, long index)
{
    tuckSeqBounds(index, cast(long) items.length, "at");
    return items[index];
}

T at(T)(T[] items, long index)
{
    return tuckAt(items, index);
}

void tuckSetAt(T)(ref T[] items, long index, T value)
{
    tuckSeqBounds(index, cast(long) items.length, "setAt");
    items[index] = value;
}

void setAt(T)(ref T[] items, long index, T value)
{
    tuckSetAt(items, index, value);
}

/// `Array[N, T]` needs its OWN pair, separate from tuckAt/tuckSetAt above.
/// core.array's `atFixed` cannot be a plain Tuck function using `items[i]`:
/// the bracket-index dispatch routes to whatever `fn at` is in scope, which —
/// inside `at`'s OWN body — is `at` itself, so a Tuck-body `at` for
/// `Array[N, T]` would self-recurse infinitely rather than indexing.
/// core.array's accessor calls THIS directly by name (an ordinary call, not
/// bracket sugar), so there is no body to recurse in.
T tuckArrayAt(T, size_t N)(T[N] items, long index)
{
    tuckSeqBounds(index, cast(long) N, "at");
    return items[index];
}

void tuckArraySetAt(T, size_t N)(ref T[N] items, long index, T value)
{
    tuckSeqBounds(index, cast(long) N, "setAt");
    items[index] = value;
}

/// Value semantics: `~` always allocates a fresh array rather than growing
/// `items` in place (unlike `~=`, which may reuse spare capacity from the
/// same backing GC block) — `items` is never mutated by this call.
long getLength(T)(T x) { return cast(long) x.length; }

long count(T)(T[] items) { return cast(long) items.length; }

long byteCount(string t) { return cast(long) t.length; }

string fromBytes(ubyte[] bytes)
{
    return cast(string) bytes.idup;
}

ubyte byteAt(string t, long index)
{
    tuckSeqBounds(index, cast(long) t.length, "byteAt");
    return cast(ubyte) t[index];
}

/// Absent, not an error: "that text is not a number" has a legitimate no.
TuckResult!double parseFloat(string t)
{
    try { return tok(to!double(t)); }
    catch (Exception) { return tnone!double(); }
}

/// One pass — `acc ~= part` on a string in a loop is O(n^2).
string joinStr(string[] parts, string sep)
{
    return parts.join(sep);
}

T[] push(T)(T[] items, T value)
{
    return items ~ [value];
}

/// Bit operations. Tuck has no bitwise OPERATORS — `|` is already sum-variant
/// syntax and a word operator is refused (TK-PA11) — so these are ordinary
/// postfix calls declared in std/bits.tuck, the same shape std/seq.tuck uses
/// for at/setAt. Everything that wants bits is written against them.
ulong bitAnd(ulong a, ulong b) { return a & b; }
ulong bitOr(ulong a, ulong b) { return a | b; }
ulong bitXor(ulong a, ulong b) { return a ^ b; }
ulong bitNot(ulong a) { return ~a; }

/// A shift at or past the width is 0, not undefined — C leaves `x << 64`
/// undefined and each backend inherits that, so the guard lives here.
ulong shiftLeft(ulong a, long by)
{
    if (by >= 64 || by < 0) return 0;
    return a << by;
}

ulong shiftRight(ulong a, long by)
{
    if (by >= 64 || by < 0) return 0;
    return a >> by;
}

string charAt(string s, long index)
{
    tuckSeqBounds(index, cast(long) s.length, "charAt");
    return [s[index]].idup;
}

bool containsChar(string s, string ch)
{
    import std.algorithm : canFind;
    return s.canFind(ch);
}

string[] splitLines(string s)
{
    import std.string : stdSplitLines = splitLines;
    return stdSplitLines(s);
}

int ord(string ch)
{
    tuckSeqBounds(0, cast(long) ch.length, "ord");
    return cast(int) ch[0];
}

/// Fill the CALLER's record shape from named values.
///
/// A record-returning extern (`fn argCount() -> {count: int}`) is declared in
/// Tuck, so the emitter names its own hoisted TRec struct for it — the
/// runtime cannot spell that name. Odin's runtime declares a parallel struct
/// per extern and relies on structural compatibility; D can take the shape as
/// a template parameter and assign by FIELD NAME instead, so one helper
/// serves every such extern and a field-order change cannot silently
/// mis-assign.
R tuckRec(R, names...)(typeof(mixin("R." ~ names[0])) value)
    if (names.length == 1)
{
    R r;
    mixin("r." ~ names[0] ~ " = value;");
    return r;
}

/// std/console — one line of stdin, without its newline. End of input is an
/// ERROR (IoError.EndOfInput), not absence: std/console declares it that
/// way, so a caller tells "nothing left" from "a blank line" by the status.
R readLine(R)()
{
    import std.stdio : stdin;
    alias P = typeof(R.value);
    auto line = stdin.readln();
    if (line.length == 0)
        return terr!P(errCode("console/IoError.EndOfInput"));
    while (line.length > 0 && (line[$ - 1] == '\n' || line[$ - 1] == '\r'))
        line = line[0 .. $ - 1];
    return tok(tuckRec!(P, "line")(line.idup));
}

/// A spinlock for the mailbox. NOT decoration: this runtime spawns one OS
/// thread per actor (tuck_coro.d's tuckStartActor), so a send from main and
/// a drain on the actor's thread genuinely race. The mailbox carried no
/// synchronisation at all until 2026-09-20 — the comment here still said
/// "cooperative on ONE thread", which stopped being true when actors got
/// their own threads and nobody updated it (KNOWN-BUGS-EVENTS.md EV-5).
///
/// A spinlock rather than a Mutex for the reason the Nim runtime measured:
/// the section is a bounds check, one array write and an index bump, and a
/// busy actor should find it free without paying a futex round trip.
struct MailboxLock
{
    private shared bool flag;

    void lock()
    {
        while (cas(&flag, false, true) == false)
            while (atomicLoad(flag)) { /* spin */ }
    }

    void unlock() { atomicStore(flag, false); }
}

/// An actor's mailbox: TWO buffers, not one ring. Senders fill `buf[cur]`;
/// the actor flips `cur` and then owns the buffer it took outright, so the
/// whole drain runs with no lock held and nothing copied out. A handover is
/// one integer write whatever the batch size.
///
/// Mirrors compiler/tuck_rt.nim. `[queue: N]` means "N messages may be
/// waiting to be picked up", and an actor may hold up to another N it has
/// already taken.
struct Mailbox(T, size_t Cap)
{
    T[2][Cap] bufStore;             // buf[which][index]
    ubyte[64] pad;                  // keeps the control block off the last
                                    // cache line of the buffers: the actor
                                    // streams one while senders hammer the
                                    // lock, and sharing a line makes them
                                    // invalidate each other for nothing
    size_t[2] fill;
    size_t cur;
    MailboxLock lock;

    /// Take everything waiting and hand it over IN PLACE. The swap happens
    /// once, up front, under the lock; every iteration after that touches a
    /// buffer no sender can reach.
    ///
    /// `fill` is cleared before the first element rather than after the
    /// last, so an early exit leaves the mailbox consistent instead of
    /// re-delivering a batch.
    int opApply(scope int delegate(ref T) dg)
    {
        lock.lock();
        immutable c = cur;
        immutable n = fill[c];
        if (n > 0)
        {
            cur = 1 - c;            // THE SWAP: the actor now owns buf[c]
            fill[c] = 0;
        }
        lock.unlock();
        foreach (i; 0 .. n)
        {
            int r = dg(bufStore[i][c]);
            if (r) return r;
        }
        return 0;
    }
}

/// Returns false when the mailbox is FULL — the message is dropped.
///
/// That is the existing de-facto behaviour of the Nim runtime, matched here
/// deliberately rather than improved on: the spec states no full-mailbox
/// policy (FRICTIONS.md #9), so choosing one is a language decision, not a
/// backend's. Verified consequence, recorded in the actor playground: a
/// waitUntil whose predicate needs the dropped messages spins forever, on
/// the Nim backend too.
bool enqueue(T, size_t Cap)(ref Mailbox!(T, Cap) mb, T msg)
{
    mb.lock.lock();
    immutable c = mb.cur;
    if (mb.fill[c] >= Cap)
    {
        mb.lock.unlock();
        return false;
    }
    mb.bufStore[mb.fill[c]][c] = msg;
    mb.fill[c]++;
    mb.lock.unlock();
    return true;
}

bool hasRoom(T, size_t Cap)(ref Mailbox!(T, Cap) mb)
{
    mb.lock.lock();
    immutable r = mb.fill[mb.cur] < Cap;
    mb.lock.unlock();
    return r;
}

void initMailbox(T, size_t Cap)(ref Mailbox!(T, Cap) mb) {}  // nothing to do

/// A fixed-count object pool (spec 7.2). N slots decided at compile time, so
/// the footprint is static — that is the whole point of the declaration.
///
/// `acquire` returns `?T`: exhaustion is ABSENCE, not an error. A count is a
/// real-world fact and running out is backpressure, so the caller matches on
/// it rather than handling a failure.
/// Where one cell stands. A cell STARTS ABSENT (#42): it reads absent until
/// something writes it, so zeroed storage is never read as a value of the
/// element type. Twin of tuck_rt.nim's CellState.
enum CellState : ubyte { free, absent, present }

struct ObjectPool(T, size_t Count)
{
    T[Count] storage;
    uint[Count] gen;          /// tenancy counter per cell; 0 = never handed out
    CellState[Count] state;   /// one per cell; was a ulong, capping a pool at 64
}

/// What `acquire` hands back: WHICH cell, and WHICH TENANCY of it. The value
/// used to be the cell's contents, so the cell's identity was gone by the time
/// `release` needed it — it matched by equality, every slot held the same zero
/// value, and every release freed slot 0. Same shape in all three runtimes.
struct PoolHandle
{
    int slot;
    uint gen;
}

// ---------------------------------------------------------------------------
// spec 7.4: the resource registry. The D twin of tuck_rt.nim's — same
// structure, same policies, same LIFO close-all. See the Nim copy for why
// each piece is shaped the way it is; this file states the D spelling.

/// What an acquire hands back: WHICH entry, and WHICH TENANCY of it. A plain
/// value, never the resource itself — the ref stays in the table, which is
/// what closes the fd-reuse bug class by construction.
struct ResourceHandle
{
    int slot;
    uint gen;
}

/// When the OS handle actually closes. MARKING is identical under all three,
/// so buggy code behaves the same way in every mode.
enum RtResourcePolicy : ubyte
{
    Strict, /// close at the mark. Deterministic; the embedded/debug default
    Lazy,   /// mark only; the inline watermark sweep reclaims
    Exit,   /// close-all at program end
}

/// What a CAPPED table does when it fills.
enum RtOnFull : ubyte
{
    Absent, /// report absence; the caller decides (the default)
    Error,  /// abort, naming the kind and its cap
}

/// How THIS kind's OS handle is released. A callback because the runtime
/// cannot know: an fd, an mmap and a TLS session are three different syscalls.
alias ResourceCloser = void function(long reference);

/// spec 7.4's `on_finish` vocabulary, as real syscalls on the reference. The
/// declaration PICKS one and the emitted table binds it, so there is one
/// mechanism — setResourceHooks overrides the same field, which is the escape
/// hatch for a kind whose reference is not an fd at all.
///
/// A failed syscall is deliberately not reported: on_finish runs at the MARK,
/// where the program has already said it is done with the handle.
void tuckResFlush(long reference)
{
    import core.sys.posix.unistd : fsync;
    cast(void) fsync(cast(int) reference);
}

void tuckResShutdown(long reference)
{
    import core.sys.posix.sys.socket : shutdown, SHUT_RDWR;
    cast(void) shutdown(cast(int) reference, SHUT_RDWR);
}

struct ResourceEntry
{
    long reference;  /// the OS handle: an fd, or a pointer cast to int
    uint gen;        /// tenancy; bumped at the MARK, so the handle dies there
    bool live;       /// this slot is occupied at all
    bool finished;   /// marked; awaiting reclamation. Only these are evicted
    string site;     /// where it was acquired — the report's whole value
}

struct ResourceTable
{
    string kind;
    int cap;         /// 0 = unbounded (slice-backed); >0 = the bound
    RtResourcePolicy policy;
    RtOnFull onFull; /// only consulted when `cap` > 0
    int sweepBatch;  /// 0 = evict every finished entry; >0 = that many
    ResourceCloser onFinish;  /// runs at the MARK, always (file: flush)
    ResourceCloser onClose;   /// runs at reclamation
    ResourceEntry[] entries;
    int[] order;     /// registration order — close-all walks it backwards
    int finishedCount;
}

void tuckResourceMisuse(string table, string what)
{
    // Stops rather than returning, for the reason tuckPoolMisuse does: a
    // stale handle that writes to a REUSED slot is the bug 7.4 exists to
    // make impossible.
    //
    // exit(1), NOT abort(). Nim quits 1 and Odin os.exit(1); abort() raised
    // SIGABRT and dumped core, so the same program ended three different ways
    // depending on the backend — and a shipped D binary wrote a core file
    // where the others exited quietly (issue #54).
    import std.stdio : stderr;
    import core.stdc.stdlib : exit;
    stderr.writeln("TUCK RESOURCE [", table, "]: ", what);
    exit(1);
}

void initResourceTable(ref ResourceTable t, string kind, int cap,
                       RtResourcePolicy policy, int sweepBatch,
                       RtOnFull onFull = RtOnFull.Absent)
{
    t.kind = kind;
    t.cap = cap;
    t.policy = policy;
    t.sweepBatch = sweepBatch;
    t.onFull = onFull;
    // A capped kind is array-shaped from the start: the cap is a LINK-TIME
    // memory budget, not a limit discovered at runtime.
    if (cap > 0 && t.entries.length < cap)
        t.entries.length = cap;
}

void setResourceHooks(ref ResourceTable t, ResourceCloser onFinish,
                      ResourceCloser onClose)
{
    t.onFinish = onFinish;
    t.onClose = onClose;
}

private void rtReclaim(ref ResourceTable t, size_t i)
{
    // Never called on a LIVE entry: 7.4 has no time-based eviction, and an
    // entry nobody finished is still in use by definition.
    if (!t.entries[i].live || !t.entries[i].finished) return;
    if (t.onClose !is null) t.onClose(t.entries[i].reference);
    t.entries[i].live = false;
    t.entries[i].site = "";
    t.finishedCount--;
    foreach (k, slot; t.order)
        if (slot == cast(int) i)
        {
            t.order = t.order[0 .. k] ~ t.order[k + 1 .. $];
            break;
        }
}

/// Also the `kind::sweep` an explicit scheduled cleanup calls — the inline
/// trigger and the explicit one are one function, so a program that sweeps by
/// hand and one that lets the marks do it cannot drift apart.
int sweepResources(ref ResourceTable t)
{
    int taken = 0;
    const limit = t.sweepBatch > 0 ? t.sweepBatch : cast(int) t.entries.length;
    foreach (i; 0 .. t.entries.length)
    {
        if (taken >= limit) break;
        if (t.entries[i].live && t.entries[i].finished)
        {
            rtReclaim(t, i);
            taken++;
        }
    }
    return taken;
}

private bool rtWatermarkReached(ref ResourceTable t)
{
    // ~75% of cap. An uncapped table has no watermark: its bound is the OS
    // ulimit, and there is no budget to measure against.
    return t.cap > 0 && (t.finishedCount * 4) >= (t.cap * 3);
}

/// Exhaustion is ABSENCE, not an error — the caller decides what running out
/// means, exactly as 7.2's pool does.
TuckResult!ResourceHandle acquireResource(ref ResourceTable t, long reference,
                                          string site)
{
    // Sizes a capped table on first use, so a table built as a plain literal
    // behaves exactly as one built through initResourceTable — which is what
    // lets the backend emit the declaration with no start-up code at all.
    if (t.cap > 0 && t.entries.length < t.cap) t.entries.length = t.cap;
    foreach (i; 0 .. t.entries.length)
    {
        if (t.entries[i].live) continue;
        t.entries[i].gen++;
        t.entries[i].reference = reference;
        t.entries[i].live = true;
        t.entries[i].finished = false;
        t.entries[i].site = site;
        t.order ~= cast(int) i;
        return tok(ResourceHandle(cast(int) i, t.entries[i].gen));
    }
    // The cap is the leak alarm as much as the budget: a table that FILLS is
    // a bug surfacing early rather than an OOM three days in. Which of those
    // two readings applies is the kind's own `on_full`.
    if (t.cap > 0)
    {
        if (t.onFull == RtOnFull.Error)
            tuckResourceMisuse(t.kind,
                "table is full and the kind declares `on_full: error`");
        return tnone!ResourceHandle();
    }
    ResourceEntry e;
    e.reference = reference;
    e.gen = 1;
    e.live = true;
    e.site = site;
    t.entries ~= e;
    t.order ~= cast(int)(t.entries.length - 1);
    return tok(ResourceHandle(cast(int)(t.entries.length - 1), 1));
}

private size_t rtEntryFor(ref ResourceTable t, ResourceHandle h, string what)
{
    // Every way of being wrong is caught rather than absorbed: out of range,
    // never handed out, and — the one that matters — a generation that has
    // moved on, which is a handle held past its finish.
    //
    // `what` names the OPERATION, and the message says which slot and which
    // tenancies — that is the whole diagnosis. Worded exactly as the Nim
    // runtime words it, so one program reports one thing whichever backend
    // built it.
    import std.conv : text;
    const i = h.slot;
    if (i < 0 || i >= t.entries.length)
        tuckResourceMisuse(t.kind,
            text(what, " of a handle that names no slot (", i, ")"));
    else if (!t.entries[i].live)
        tuckResourceMisuse(t.kind,
            text(what, " of slot ", i, ", which nobody holds"));
    else if (t.entries[i].gen != h.gen)
        tuckResourceMisuse(t.kind,
            text(what, " of a stale handle for slot ", i, ": tenancy ",
                 h.gen, ", slot is on ", t.entries[i].gen));
    return cast(size_t) i;
}

/// The only way to reach the OS handle, which is what makes the generation
/// check unavoidable rather than something a caller can forget.
long derefResource(ref ResourceTable t, ResourceHandle h)
{
    return t.entries[rtEntryFor(t, h, "use")].reference;
}

/// 7.4's mark: release INTENT, not necessarily release. on_finish runs, the
/// entry is marked, and the generation bumps — under every policy, so the
/// handle dies AT THE MARK. Only reclamation is policy, which is what makes
/// durability independent of sweep timing.
void finishResource(ref ResourceTable t, ResourceHandle h)
{
    const i = rtEntryFor(t, h, "finish");
    if (t.onFinish !is null) t.onFinish(t.entries[i].reference);
    t.entries[i].finished = true;
    t.entries[i].gen++;
    t.finishedCount++;
    final switch (t.policy)
    {
        case RtResourcePolicy.Strict:
            rtReclaim(t, i);
            break;
        case RtResourcePolicy.Lazy:
            // Sweeping is INLINE — no thread, no background actor. The
            // trigger lives in the mark itself, so a loop acquiring ten
            // thousand times against a cap in the thousands never blocks.
            if (rtWatermarkReached(t)) sweepResources(t);
            break;
        case RtResourcePolicy.Exit:
            break;
    }
}

/// LIFO in REGISTRATION order: files flush before the directories holding
/// them close, a TLS session shuts down before the socket under it.
void closeAllResources(ref ResourceTable t)
{
    foreach_reverse (slot; t.order)
    {
        const i = cast(size_t) slot;
        if (!t.entries[i].live) continue;
        if (!t.entries[i].finished && t.onFinish !is null)
            t.onFinish(t.entries[i].reference);
        if (t.onClose !is null) t.onClose(t.entries[i].reference);
        t.entries[i].live = false;
        t.entries[i].finished = false;
        t.entries[i].site = "";
    }
    t.order.length = 0;
    t.finishedCount = 0;
}

int openResourceCount(ref ResourceTable t)
{
    int n = 0;
    foreach (slot; t.order)
    {
        const i = cast(size_t) slot;
        if (t.entries[i].live && !t.entries[i].finished) n++;
    }
    return n;
}

/// 7.4's OPEN RESOURCES report. Debug builds only — `version(assert)` is on
/// unless the build passed -release, which is what "debug build" means here —
/// and silent when there is nothing to say: a report that prints "0" every
/// run is one people stop reading.
void reportOpenResources(ref ResourceTable t)
{
    version (assert)
    {
        import std.stdio : stderr;
        const n = openResourceCount(t);
        if (n == 0) return;
        stderr.writeln("OPEN RESOURCES [", t.kind, "] (", n, "):");
        foreach (slot; t.order)
        {
            const i = cast(size_t) slot;
            if (t.entries[i].live && !t.entries[i].finished)
                stderr.writeln("  slot ", i, " acquired at ", t.entries[i].site);
        }
    }
}

/// SAY what leaked, then close everything — in that order, since close-all
/// empties the table and a report after it is always silent.
void shutdownResources(ref ResourceTable t)
{
    reportOpenResources(t);
    closeAllResources(t);
}

void tuckPoolMisuse(string what)
{
    // Stops rather than returning: the alternative is the silent corruption
    // this replaced. exit(1), NOT abort() — the same end as Nim's quit(1) and
    // Odin's os.exit(1), for the reason tuckResourceMisuse gives (issue #54):
    // abort() raised SIGABRT and dumped core where the others exited quietly.
    import std.stdio : stderr;
    import core.stdc.stdlib : exit;
    stderr.writeln("TUCK POOL: ", what);
    exit(1);
}

TuckResult!PoolHandle tuckPoolAcquire(T, size_t Count)(ref ObjectPool!(T, Count) pool)
{
    foreach (i; 0 .. Count)
    {
        if (pool.state[i] == CellState.free)
        {
            pool.state[i] = CellState.absent;
            pool.gen[i] += 1;
            return tok(PoolHandle(cast(int) i, pool.gen[i]));
        }
    }
    return tnone!PoolHandle();
}

/// The cell a handle names, if its holder still holds it. Every way of being
/// wrong is caught rather than absorbed; the messages match the Nim and Odin
/// runtimes word for word.
private size_t heldCell(T, size_t Count)(ref ObjectPool!(T, Count) pool,
                                        PoolHandle h, string what)
{
    import std.format : format;
    const i = h.slot;
    if (i < 0 || i >= Count)
        tuckPoolMisuse(format("%s of a handle that names no slot (%d)", what, i));
    else if (pool.state[i] == CellState.free)
        tuckPoolMisuse(format("%s of slot %d, which nobody holds", what, i));
    else if (pool.gen[i] != h.gen)
        tuckPoolMisuse(format("%s of a stale handle for slot %d: tenancy %d, slot is on %d",
                              what, i, h.gen, pool.gen[i]));
    return cast(size_t) i;
}

void tuckPoolRelease(T, size_t Count)(ref ObjectPool!(T, Count) pool, PoolHandle h)
{
    pool.state[heldCell(pool, h, "release")] = CellState.free;
}

TuckResult!T tuckPoolRead(T, size_t Count)(ref ObjectPool!(T, Count) pool, PoolHandle h)
{
    const i = heldCell(pool, h, "read");
    if (pool.state[i] == CellState.present) return tok(pool.storage[i]);
    return tnone!T();
}

void tuckPoolWrite(T, size_t Count)(ref ObjectPool!(T, Count) pool, PoolHandle h, T v)
{
    const i = heldCell(pool, h, "write");
    pool.storage[i] = v;
    pool.state[i] = CellState.present;
}

/// The cell's bytes, for an extern to fill (DMA). Present from here on: it
/// was handed out to be filled, and the checker allows addr only on a pool
/// whose element carries no invariant (TK-TY31).
ubyte* tuckPoolAddr(T, size_t Count)(ref ObjectPool!(T, Count) pool, PoolHandle h)
{
    const i = heldCell(pool, h, "addr");
    pool.state[i] = CellState.present;
    return cast(ubyte*) &pool.storage[i];
}

// std/fs — the filesystem. The error codes are the FsError variants the
// Tuck declaration names, hashed the same way every backend hashes them.
//
// These all block: a regular file is always "ready" to epoll, so the
// reactor cannot await one. They run on the worker via tuckSubmitBlocking
// (tuck_coro.d), which parks the calling coroutine on a completion pipe —
// mirrors tuck_rt.nim and tuckrt/tuck_rt.odin, now that the coroutine
// runtime is here to offload onto (portable runtime CHARACTERISTICS, not
// just semantics: a program must not behave as if every other coroutine,
// actor and timer froze for the duration of a file read, regardless of
// which backend built it).
//
// Raw C calls, not std.file: the worker's request crosses the
// tuckSubmitBlocking boundary as a MALLOC'd struct (see tuckSubmitBlocking's
// own comment) — a GC-managed std.file result reachable only from the
// calling coroutine's unscanned minicoro stack while it is parked is not
// safe to hold onto. Growing the read buffer with malloc/realloc mirrors
// tuck_rt.nim's fileWorker exactly, for the identical reason.

private enum FileOp : ubyte { Read, Write, Append, Remove }
private enum FsIoStatus : ubyte { Ok, NotFound, IoFailed, AccessDenied }

private struct FileReq
{
    FileOp op;
    const(char)* path;    // NUL-terminated; alive for the whole call
    const(void)* data;    // write/append payload; alive for the whole call
    size_t dataLen;
    void* outBuf;         // Read: malloc'd by the worker, freed by the caller
    size_t outLen;
    FsIoStatus status = FsIoStatus.Ok;
}

private void fileWorker(void* arg)
{
    import core.stdc.stdlib : malloc, realloc, free;
    import core.stdc.errno : errno, ENOENT;
    import core.sys.posix.fcntl : open, O_RDONLY, O_WRONLY, O_CREAT, O_TRUNC,
        O_APPEND;
    import core.sys.posix.unistd : unlink;

    auto r = cast(FileReq*) arg;
    final switch (r.op)
    {
    case FileOp.Remove:
        if (unlink(r.path) != 0)
            r.status = errno == ENOENT ? FsIoStatus.NotFound
                                        : FsIoStatus.AccessDenied;
        break;
    case FileOp.Write, FileOp.Append:
        int flags = O_WRONLY | O_CREAT |
                    (r.op == FileOp.Append ? O_APPEND : O_TRUNC);
        int fd = open(r.path, flags, 0x1A4);   // 0o644
        if (fd < 0) { r.status = FsIoStatus.AccessDenied; break; }
        size_t off = 0;
        auto p = cast(const(ubyte)*) r.data;
        while (off < r.dataLen)
        {
            auto n = write(fd, p + off, r.dataLen - off);
            if (n <= 0) { r.status = FsIoStatus.AccessDenied; break; }
            off += n;
        }
        close(fd);
        break;
    case FileOp.Read:
        int fd = open(r.path, O_RDONLY, 0);
        if (fd < 0)
        {
            r.status = errno == ENOENT ? FsIoStatus.NotFound
                                        : FsIoStatus.IoFailed;
            break;
        }
        // Grow-on-demand with malloc, not a GC array: the worker's result
        // must survive a collection triggered while the calling coroutine
        // (the only thing that will ever reference it) is parked on an
        // unscanned stack. Starts at 64K and doubles, so an ordinary file
        // is one allocation.
        size_t cap = 65536;
        auto buf = malloc(cap);
        size_t len = 0;
        while (true)
        {
            if (len == cap)
            {
                cap *= 2;
                auto bigger = realloc(buf, cap);
                if (bigger is null)
                {
                    free(buf);
                    close(fd);
                    r.status = FsIoStatus.IoFailed;
                    return;
                }
                buf = bigger;
            }
            auto n = read(fd, cast(ubyte*) buf + len, cap - len);
            if (n < 0)
            {
                free(buf);
                close(fd);
                r.status = FsIoStatus.IoFailed;
                return;
            }
            if (n == 0) break;
            len += n;
        }
        close(fd);
        r.outBuf = buf;
        r.outLen = len;
        break;
    }
}

/// Set up the request on the SCHEDULER thread, hand it to the worker, park.
/// `path`/`data` are copied into malloc'd, NUL-terminated buffers that stay
/// alive for the whole call — the coroutine cannot proceed until the worker
/// signals, so the worker's view of them is always valid.
private FileReq runFileOp(FileOp op, string path, string data = "")
{
    import core.stdc.stdlib : malloc, free;
    import core.stdc.string : memcpy;

    auto pathBuf = cast(char*) malloc(path.length + 1);
    memcpy(pathBuf, path.ptr, path.length);
    pathBuf[path.length] = 0;
    char* dataBuf;
    if (data.length > 0)
    {
        dataBuf = cast(char*) malloc(data.length);
        memcpy(dataBuf, data.ptr, data.length);
    }

    FileReq req;
    req.op = op;
    req.path = pathBuf;
    req.data = dataBuf;
    req.dataLen = data.length;
    tuckSubmitBlocking(&fileWorker, &req);

    free(pathBuf);
    if (dataBuf !is null) free(dataBuf);
    return req;
}

/// One place mapping a worker outcome onto the FsError variants declared in
/// std/fs.tuck. Exhaustive, so a new FsIoStatus is a compile error here
/// rather than a silently wrong error code at four call sites.
private ushort fsErrCode(FsIoStatus s)
{
    final switch (s)
    {
    case FsIoStatus.NotFound:     return errCode("fs/FsError.NotFound");
    case FsIoStatus.AccessDenied: return errCode("fs/FsError.AccessDenied");
    case FsIoStatus.Ok, FsIoStatus.IoFailed:
        return errCode("fs/FsError.IoFailed");
    }
}

R readFile(R)(string path)
{
    import core.stdc.stdlib : free;
    alias P = typeof(R.value);
    auto r = runFileOp(FileOp.Read, path);
    if (r.status != FsIoStatus.Ok) return terr!P(fsErrCode(r.status));
    auto content = (cast(char*) r.outBuf)[0 .. r.outLen].idup;
    if (r.outBuf !is null) free(r.outBuf);
    return tok(tuckRec!(P, "content")(content));
}

TuckResult!TuckUnit writeFile(string path, string content)
{
    auto r = runFileOp(FileOp.Write, path, content);
    if (r.status != FsIoStatus.Ok) return terr!TuckUnit(fsErrCode(r.status));
    return tokVoid();
}

/// NOT a result: a stat that says "no" is an answer, not a failure — the
/// Tuck declaration returns a plain bool and the Nim runtime agrees. NOT
/// offloaded either: a stat is a metadata lookup, microseconds on any live
/// filesystem, and paying a thread handoff plus a pipe round-trip would
/// cost more than the call — mirrors the Nim and Odin runtimes.
bool fileExists(string path)
{
    import std.file : exists;
    return exists(path);
}

/// Idempotent by an explicit existence check, same as the Nim and Odin
/// runtimes, so all three backends agree on the same contract rather than
/// relying on each platform's own already-exists behavior for mkdir -p.
TuckResult!TuckUnit makeDir(string path)
{
    import std.file : exists, mkdirRecurse, FileException;
    if (exists(path)) return tokVoid();
    try
    {
        mkdirRecurse(path);
        return tokVoid();
    }
    catch (FileException e)
    {
        return terr!TuckUnit(errCode("fs/FsError.IoFailed"));
    }
}

TuckResult!TuckUnit removeFile(string path)
{
    auto r = runFileOp(FileOp.Remove, path);
    if (r.status != FsIoStatus.Ok) return terr!TuckUnit(fsErrCode(r.status));
    return tokVoid();
}

TuckResult!TuckUnit appendFile(string path, string content)
{
    auto r = runFileOp(FileOp.Append, path, content);
    if (r.status != FsIoStatus.Ok) return terr!TuckUnit(fsErrCode(r.status));
    return tokVoid();
}

// std/sys — process control and the command line. argCount/argAt exclude
// argv[0], matching Nim's paramCount/paramStr and the Odin runtime.
private string[] tuckArgs;

void tuckSetArgs(string[] args) { tuckArgs = args; }

R argCount(R)()
{
    long n = tuckArgs.length > 0 ? cast(long) tuckArgs.length - 1 : 0;
    return tuckRec!(R, "count")(n);
}

R argAt(R)(long index)
{
    if (index < 0 || index + 1 >= cast(long) tuckArgs.length)
        return tuckRec!(R, "arg")("");
    return tuckRec!(R, "arg")(tuckArgs[cast(size_t) index + 1]);
}

/// `?{value: str}` — an unset variable is ABSENT, not an error and not an
/// empty string. Absence is a first-class status, so the caller matches on
/// it rather than comparing against a sentinel.
R getEnv(R)(string name)
{
    import std.process : environment;
    alias P = typeof(R.value);
    auto v = environment.get(name);
    if (v is null) return tnone!P();
    return tok(tuckRec!(P, "value")(v));
}

void exit(long code)
{
    import core.stdc.stdlib : cexit = exit;
    cexit(cast(int) code);
}

// std/time — the wall clock, and a sleep. Until the coroutine runtime lands
// there are no other tasks to keep running, so a blocking sleep IS the
// reactor semantics for a single-task program.
R nowMs(R)()
{
    import std.datetime.systime : Clock;
    return tuckRec!(R, "ms")(
        cast(ulong)(Clock.currStdTime / 10_000 - 62_135_596_800_000L));
}

void sleepMs(uint ms)
{
    import core.thread : Thread;
    import core.time : msecs;
    Thread.sleep(msecs(ms));
}

// --- a demo async source -----------------------------------------------
// A REAL non-blocking source: a pipe whose write end is fed by a writer
// coroutine after `ms` (a reactor-driven sleep, no OS thread). The read fd
// genuinely becomes readable at `ms`, so a task racing `read fd` against
// `timeout N` sees the true winner. Mirrors tuck_async.nim's openSource and
// tuckrt/tuck_coro.odin's openSource — the runtimes must agree on what
// "async" means, or a program's behaviour would depend on which backend
// built it.
//
// Unlike the Odin port, D HAS real closures, so the writer coroutine simply
// captures `ms` and the write fd by delegate — no context.user_ptr
// marshaling layer is needed (that machinery exists only because Odin's
// `proc()` literals cannot read an outer local).
R openSource(R)(long ms)
{
    int[2] pipes;
    if (pipe2(pipes, 0) != 0) return tuckRec!(R, "fd")(-1L);
    auto wr = pipes[1];
    tuckSpawn({
        tuckSleep(ms);
        ubyte[1] b = [1];
        write(wr, b.ptr, 1);
        close(wr);
    });
    return tuckRec!(R, "fd")(cast(long) pipes[0]);
}
