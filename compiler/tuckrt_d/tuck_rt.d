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
import core.sys.posix.unistd : pipe2, read, write, posixClose = close;
import core.atomic : cas, atomicLoad, atomicStore;

// The coroutine engine is a separate file but the SAME facade: emitted code
// reaches everything through `rt`, so tuck_rt re-exports it — mirroring
// tuck_rt.nim, which fronts tuck_async the same way.
public import tuck_coro;

/// MEMORY IS THE PROGRAM'S. The ownership rules decide every copy, move and
/// drop (compiler/ownership_write.nim) and the emitted program carries them
/// out; the collector does not run. It stays the allocator, and it collects
/// only when an allocation would otherwise fail, which makes a missed drop
/// a cost and never a crash.
shared static this() {
    import core.memory : GC;
    GC.disable();
}

/// `-version=tuckTrack`: the bytes the program allocated and never freed,
/// reported at exit (the allocation tracker's counterpart on Odin). Zero
/// when the ownership rules' drops free everything. Without the version
/// both calls are nothing.
private ulong tuckLeakBase;
void tuckLeakMark() {
    version (tuckTrack) {
        import core.memory : GC;
        // The allocator keeps a little state the first time a size class is
        // used (measured: 16 bytes at a program's first array literal). That
        // is not the program's, so every size is used once, and freed, before
        // the baseline is taken.
        foreach (n; [1, 2, 3, 4, 8, 16, 24, 48, 100, 300, 1000, 4000]) {
            auto w = new ubyte[](n); tuckFreeBlock(cast(void*) w.ptr);
            auto v = new long[](n); tuckFreeBlock(cast(void*) v.ptr);
        }
        tuckLeakBase = GC.stats().usedSize;
    }
}
int tuckLeakCheck(int rc) {
    version (tuckTrack) {
        import core.memory : GC;
        import core.stdc.stdio : fprintf, stderr;
        auto used = GC.stats().usedSize;
        if (used > tuckLeakBase) {
            fprintf(stderr, "TUCK-ALLOC: %llu bytes never freed\n",
                    cast(ulong) (used - tuckLeakBase));
            return 90;
        }
    }
    return rc;
}

/// A drop (rule D): free what a value of `T` owns, deeply, and leave it
/// empty. A slice's block, each element first when they own storage, a
/// struct's fields, a payload sum's live variant (the `tuckFree` the emitter
/// gives every one). `tuckFreeBlock` leaves what the collector did not
/// allocate (a literal) and a slice into the middle of a block alone.
void tuckDrop(T)(ref T v) {
    import core.memory : GC;
    import std.traits : isDynamicArray, isStaticArray, hasIndirections;
    static if (__traits(hasMember, T, "tuckFree")) {
        v.tuckFree();
    } else static if (isDynamicArray!T) {
        alias E = typeof(v[0]);
        static if (hasIndirections!E && !is(E == immutable))
            foreach (ref x; v) tuckDrop(x);
        tuckFreeBlock(cast(void*) v.ptr);
        v = null;
    } else static if (isStaticArray!T) {
        foreach (ref x; v) tuckDrop(x);
    } else static if (is(T == struct)) {
        foreach (ref f; v.tupleof) tuckDrop(f);
    }
}

/// An overwrite that drops the old value (rule D): the new one is built
/// first (it is the argument), then the old one is dropped, then stored.
void tuckReplace(T)(ref T place, T value) {
    tuckDrop(place);
    place = value;
}

/// `xs += v` on a Seq: grown in place; when growth moved the block, the old
/// one is freed (it was only `xs`'s).
void tuckPush(T)(ref T[] xs, T v) {
    import core.memory : GC;
    auto old = xs.ptr;
    xs ~= v;
    if (old !is null && xs.ptr !is old) tuckFreeBlock(cast(void*) old);
}

/// Room for `extra` more elements, so the pushes of a counted loop that is
/// about to make them need not ask (append_fill). A block that had to move
/// is freed, as `tuckPush` does.
void tuckReserve(T)(ref T[] xs, long extra) {
    if (extra <= 0) return;
    auto old = xs.ptr;
    xs.reserve(xs.length + cast(size_t) extra);
    if (old !is null && xs.ptr !is old) tuckFreeBlock(cast(void*) old);
}

/// A push whose room `tuckReserve` made before the loop: the slice grows by
/// one and the element is stored, with no call into the runtime's append.
void tuckPushFilled(T)(ref T[] xs, T v) {
    xs = xs.ptr[0 .. xs.length + 1];
    xs[$ - 1] = v;
}

/// `s += t` on a str the body owns: the same, for its bytes.
void tuckStrAppend(ref string s, string t) {
    import core.memory : GC;
    auto old = s.ptr;
    s ~= t;
    if (old !is null && s.ptr !is old) tuckFreeBlock(cast(void*) old);
}

/// A deep copy (rule G): a value of `T` that shares no storage with `v`. A
/// slice gets a new buffer, a `str` its own bytes, a struct each field
/// copied, a payload sum its live variant (the `tuckDup` the emitter gives
/// every one). References (classes, pointers: slab refs, actors) are shared.
T tuckCopy(T)(T v) {
    import std.traits : isDynamicArray, isStaticArray, isPointer;
    static if (__traits(hasMember, T, "tuckDup")) {
        return v.tuckDup();
    } else static if (isDynamicArray!T) {
        alias E = typeof(v[0]);
        static if (is(E == immutable)) return v.idup;   // a str: its own bytes
        else {
            auto r = new E[](v.length);
            foreach (i, ref x; v) r[i] = tuckCopy(x);
            return r;
        }
    } else static if (isStaticArray!T) {
        T r = v;
        foreach (i; 0 .. T.length) r[i] = tuckCopy(v[i]);
        return r;
    } else static if (is(T == struct)) {
        T r = v;
        foreach (i, _; v.tupleof) r.tupleof[i] = tuckCopy(v.tupleof[i]);
        return r;
    } else {
        return v;
    }
}

// std/console — terminal I/O (rt-implemented externs).
void print(string s) { stdout.write(s); stdout.flush(); }
void printLine(string s) { stdout.writeln(s); }
void printError(string s) {
    import std.stdio : stderr;
    stderr.writeln(s);
    stderr.flush();
}

// `toStr` — the universal stringifier. tuck_rt.nim spells it `$value`; D's
// std.conv.text is the same "any value to its display form" operation.
// The text of a float: ONE rule on every backend (A67), written out the same
// in tuck_rt.nim, which explains it. Digits from C's snprintf and strtod;
// the layout is Python's `repr`.
private string tuckFloatLayout(bool neg, string digits, long exp) {
    while (digits.length > 1 && digits[$ - 1] == '0') digits = digits[0 .. $ - 1];
    immutable n = cast(long) digits.length;
    string body;
    if (exp >= -4 && exp < 16) {
        if (exp >= 0) {
            if (n <= exp + 1) {
                body = digits;
                foreach (_; 0 .. exp + 1 - n) body ~= '0';
                body ~= ".0";
            } else {
                body = digits[0 .. exp + 1] ~ "." ~ digits[exp + 1 .. $];
            }
        } else {
            body = "0.";
            foreach (_; 0 .. -exp - 1) body ~= '0';
            body ~= digits;
        }
    } else {
        body = digits[0 .. 1];
        if (n > 1) body ~= "." ~ digits[1 .. $];
        immutable e = exp < 0 ? -exp : exp;
        body ~= exp < 0 ? "e-" : "e+";
        if (e < 10) body ~= '0';
        body ~= text(e);
    }
    return neg ? "-" ~ body : body;
}

string tuckFloatText(double x, bool single) {
    import core.stdc.stdio : snprintf;
    import core.stdc.stdlib : strtod;
    import std.math : isNaN, isInfinity, signbit;
    import std.conv : to;
    if (isNaN(x)) return "nan";
    if (isInfinity(x)) return x > 0 ? "inf" : "-inf";
    immutable neg = signbit(x) != 0;
    if (x == 0) return neg ? "-0.0" : "0.0";
    char[64] buf;
    foreach (p; 0 .. 18) {
        snprintf(buf.ptr, buf.length, "%.*e", cast(int) p, x);
        immutable back = strtod(buf.ptr, null);
        if ((single && cast(float) back == cast(float) x) || (!single && back == x)) break;
    }
    import core.stdc.string : strlen;
    string t = buf[0 .. strlen(buf.ptr)].idup;
    string digits;
    size_t i = 0;
    if (t[i] == '-') i++;
    while (i < t.length && t[i] != 'e') {
        if (t[i] != '.') digits ~= t[i];
        i++;
    }
    long exp = to!long(t[i + 1 .. $][0] == '+' ? t[i + 2 .. $] : t[i + 1 .. $]);
    return tuckFloatLayout(neg, digits, exp);
}

string toStr(T)(T value) {
    static if (is(T == double)) return tuckFloatText(value, false);
    else static if (is(T == float)) return tuckFloatText(value, true);
    else return text(value);
}

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

/// `[v; N]` (R8): N copies of a scalar. `T[N] r = v` is D's block
/// initialisation — for a zero, the zeroed storage, not a loop.
T[N] tuckFill(T, size_t N)(T v)
{
    T[N] r = v;
    return r;
}

/// `Actor.pingUs {withinMs: n}` — the actor's answer delay in microseconds, or
/// absent when it did not answer in time. The probe is tuck_coro's; the result
/// type is here because that module cannot see TuckResult.
TuckResult!long tuckPingUs(void* handle, long withinMs)
{
    immutable ns = tuckPingNs(handle, withinMs);
    return ns < 0 ? tnone!long() : tok(ns / 1000);
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

/// Checked arithmetic on a narrow integer (issue #16, step 3): `+ - *` with the
/// overflow policy the author's type chose — trap (the default), wrap or
/// saturate. Value semantics, never stripped in release.
enum OvOp { Add, Sub, Mul }
enum OvPolicy { Trap, Wrap, Sat }

void tuckOverflowTrap(string ty, string op)
{
    import std.stdio : stderr;
    import core.stdc.stdlib : exit;
    stderr.writeln("Arithmetic overflow on ", ty, ": ", op);
    exit(1);
}

T tuckArith(T, OvOp op, OvPolicy pol)(T a, T b)
{
    import core.checkedint : adds, addu, subs, subu, muls, mulu;
    bool over = false;
    bool high = false;      // on overflow, which end the exact result is past
    T r;
    static if (T.sizeof < 8)
    {
        long w;
        static if (op == OvOp.Add) w = cast(long) a + cast(long) b;
        else static if (op == OvOp.Sub) w = cast(long) a - cast(long) b;
        else w = cast(long) a * cast(long) b;
        r = cast(T) w;
        over = w < cast(long) T.min || w > cast(long) T.max;
        high = w > 0;
    }
    else static if (__traits(isUnsigned, T))
    {
        static if (op == OvOp.Add) { r = addu(a, b, over); high = true; }
        else static if (op == OvOp.Sub) { r = subu(a, b, over); high = false; }
        else { r = mulu(a, b, over); high = true; }
    }
    else
    {
        static if (op == OvOp.Add) { r = adds(a, b, over); high = b > 0; }
        else static if (op == OvOp.Sub) { r = subs(a, b, over); high = b < 0; }
        else { r = muls(a, b, over); high = (a < 0) == (b < 0); }
    }
    if (over)
    {
        static if (pol == OvPolicy.Trap)
            tuckOverflowTrap(T.stringof,
                             op == OvOp.Add ? "+" : op == OvOp.Sub ? "-" : "*");
        else static if (pol == OvPolicy.Sat)
            return high ? T.max : T.min;
    }
    return r;
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
/// A `[depth: N]` fn was entered more than N levels deep. Real code, not
/// `assert`; exit(1) like tuckInvariantFailed.
void tuckDepthExceeded(string name, long limit)
{
    import std.stdio : stderr;
    import core.stdc.stdlib : exit;
    stderr.writeln("Recursion depth exceeded in ", name, ": limit ", limit);
    exit(1);
}

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

double sin(double value)
{
    import std.math : stdSin = sin;
    return stdSin(value);
}

double cos(double value)
{
    import std.math : stdCos = cos;
    return stdCos(value);
}

double ln(double value)
{
    import std.math : stdLog = log;
    return stdLog(value);
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

// splitmix64's finalizer: spreads an integer's bits so the low ones, which a
// table indexes by, depend on all of them. The same on every backend.
ulong tuckMix(ulong x)
{
    ulong z = x + 0x9e3779b97f4a7c15UL;
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9UL;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebUL;
    return z ^ (z >> 31);
}

// The hash of any key a table can hold: a string by its bytes (FNV-1a, as
// `hash`), an integer, bool or enum by value, anything else by its text.
ulong hashKey(T)(T key)
{
    static if (is(T == string)) return hash(key);
    else static if (__traits(isIntegral, T) || is(T == bool) || is(T == enum))
        return tuckMix(cast(ulong) key);
    else return hash(text(key));
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
/// A REFERENCE to the element, not a copy — Nim's `lent T`. By value, every
/// `xs[i].field` read copied the whole element: n-body's 56-byte record was
/// copied some 20 times per pair of planets (benches/game). A caller that
/// keeps the element (`T x = xs[i]`) still gets its own copy by assignment.
ref T tuckAt(T)(T[] items, long index)
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
    tuckDrop(items[index]);        // the element it replaces is the Seq's
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
    tuckDrop(items[index]);
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

/// A new seq that shares nothing with `items` (its elements are copied too: a
/// str or nested seq element would otherwise be freed twice, once with each
/// seq), then `value`. `tuckPush` frees the block a growth leaves.
T[] push(T)(T[] items, T value)
{
    auto r = tuckCopy(items);
    tuckPush(r, value);
    return r;
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
    // One allocation: `[s[index]].idup` builds the literal on the heap first,
    // and with the collector off nobody frees it.
    auto r = new char[](1);
    r[0] = s[index];
    return cast(string) r;
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
    auto kept = line.idup;
    tuckFreeBlock(cast(void*) line.ptr);   // readln's buffer was only ours
    return tok(tuckRec!(P, "line")(kept));
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

/// Returns false when the mailbox is FULL, and the message is not taken.
///
/// What happens then is the actor's `on_full` (R6, ruled 2026-09-28), decided
/// by the send helper the compiler emits: `sendWaiting` waits for room (the
/// default), `sendAsserting` stops the program, and `drop` discards this
/// result — which is what every send did before the ruling, when a waitUntil
/// needing a dropped message spun forever.
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

/// A send to an actor declaring `on_full: wait`, the default (R6): when the
/// mailbox is full, wait for room. `msg` is built once, by the caller.
void sendWaiting(T, size_t Cap)(ref Mailbox!(T, Cap) mb, T msg, void* handle,
                                string actor)
{
    while (!enqueue(mb, msg)) tuckAwaitRoom(handle, actor);
}

/// A send to an actor declaring `on_full: assert` (R6): a full mailbox stops
/// the program.
void sendAsserting(T, size_t Cap)(ref Mailbox!(T, Cap) mb, T msg, string actor)
{
    if (!enqueue(mb, msg))
        tuckMailboxFull(actor, "the actor declares `on_full: assert` (queue: " ~
                        Cap.to!string ~ ")");
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

// ---------------------------------------------------------------------------
// The slab (thoughts/shared/plans/2026-09-29-slab-proposal.md). The Nim twin
// (compiler/tuck_rt.nim) carries the reasoning; this mirrors it — three
// storages under one set of operations, a cell of {tenancy, link, value}, the
// free list in the dead cells, and every slab zero at the start apart from
// its name. Cells are GC-allocated, so the collector sees what they hold.

struct SlabRef { uint slot; uint gen; }

struct SlabCell(T)
{
    uint gen;
    int link;      // SLAB_LIVE while it holds a value; else next free + 1 (0 = end)
    T value;
}

enum int SLAB_LIVE = -1;
enum uint SLAB_PAGE_SHIFT = 10;
enum uint SLAB_PAGE_N = 1u << SLAB_PAGE_SHIFT;
enum uint SLAB_TOP_N = 64;
enum size_t SLAB_CHUNK_BYTES = 65536;

/// log2 of the cells per chunk: the most that fit in SLAB_CHUNK_BYTES, >= 1.
template slabChunkShift(T)
{
    enum uint slabChunkShift = () {
        uint s = 0;
        while ((2u << s) * SlabCell!T.sizeof <= SLAB_CHUNK_BYTES) s++;
        return s;
    }();
}

void tuckSlabMisuse(string name, string what)
{
    import std.stdio : stderr;
    import core.stdc.stdlib : exit;
    stderr.writeln("TUCK SLAB [", name, "]: ", what);
    exit(1);
}

struct SlabChunked(T)
{
    alias Chunk = SlabCell!T*;           // the first cell of a chunk
    alias Page = Chunk[SLAB_PAGE_N];     // a directory page of chunks
    string name;
    Page*[SLAB_TOP_N] top;
    uint len;
    int freeHead;
    long live;

    private enum uint cs = slabChunkShift!T;

    SlabCell!T* cellAt(uint i) @trusted
    {
        auto pg = top.ptr[i >> (cs + SLAB_PAGE_SHIFT)];
        return (*pg).ptr[(i >> cs) & (SLAB_PAGE_N - 1)] + (i & ((1u << cs) - 1));
    }

    uint grow()
    {
        immutable i = len;
        if ((i & ((1u << cs) - 1)) == 0)
        {
            immutable pi = i >> (cs + SLAB_PAGE_SHIFT);
            if (pi >= SLAB_TOP_N) tuckSlabMisuse(name, "full (" ~ i.to!string ~ " cells)");
            if (top[pi] is null) top[pi] = (new Page[1]).ptr;
            immutable ci = (i >> cs) & (SLAB_PAGE_N - 1);
            if ((*top[pi])[ci] is null) (*top[pi])[ci] = (new SlabCell!T[1u << cs]).ptr;
        }
        len++;
        return i;
    }
}

struct SlabFixed(T, size_t N)
{
    string name;
    SlabCell!T[N] cells;
    uint len;
    int freeHead;
    long live;

    SlabCell!T* cellAt(uint i) @trusted { return cells.ptr + i; }
    uint grow() { return len++; }
}

struct SlabSeq(T)
{
    string name;
    SlabCell!T[] cells;
    uint len;
    int freeHead;
    long live;

    SlabCell!T* cellAt(uint i) @trusted { return cells.ptr + i; }
    uint grow()
    {
        if (len == cells.length) cells ~= SlabCell!T.init;
        return len++;
    }
}

private uint slabTake(S)(ref S s)
{
    if (s.freeHead != 0)
    {
        immutable i = cast(uint)(s.freeHead - 1);
        s.freeHead = s.cellAt(i).link;
        return i;
    }
    return s.grow();
}

private SlabRef slabFill(S, T)(ref S s, uint i, T v)
{
    auto c = s.cellAt(i);
    c.gen++;
    c.link = SLAB_LIVE;
    c.value = v;
    s.live++;
    return SlabRef(i, c.gen);
}

/// A cell holding `v`. A growable slab never runs out.
SlabRef tuckSlabNew(T)(ref SlabChunked!T s, T v) { return slabFill(s, slabTake(s), v); }
/// ditto
SlabRef tuckSlabNew(T)(ref SlabSeq!T s, T v) { return slabFill(s, slabTake(s), v); }

/// `[count: N]`: absent when every cell holds a value.
TuckResult!SlabRef tuckSlabNew(T, size_t N)(ref SlabFixed!(T, N) s, T v)
{
    if (s.freeHead == 0 && s.len >= N) return tnone!SlabRef();
    return tok(slabFill(s, slabTake(s), v));
}

/// The cell `r` names, if it still holds the value `r` was made for.
auto tuckSlabCell(S)(ref S s, SlabRef r)
{
    if (r.slot >= s.len) tuckSlabMisuse(s.name, "stale reference to cell " ~ r.slot.to!string);
    auto c = s.cellAt(r.slot);
    if (c.link != SLAB_LIVE || c.gen != r.gen)
        tuckSlabMisuse(s.name, "stale reference to cell " ~ r.slot.to!string);
    return c;
}

/// Does `r` still name a live cell? The question to ask before using one.
bool tuckSlabLive(S)(ref S s, SlabRef r)
{
    if (r.slot >= s.len) return false;
    auto c = s.cellAt(r.slot);
    return c.link == SLAB_LIVE && c.gen == r.gen;
}

/// The cell is free; every reference to it is stale from here on.
void tuckSlabFree(S)(ref S s, SlabRef r)
{
    auto c = tuckSlabCell(s, r);
    tuckDrop(c.value);        // what it owns goes now, not at reuse
    c.link = s.freeHead;
    s.freeHead = cast(int) r.slot + 1;
    s.live--;
}

/// Every cell free and every reference stale: O(1) when the cells own no
/// storage, else each live cell's value is dropped first (rule D).
void tuckSlabReset(S)(ref S s)
{
    import std.traits : hasIndirections;
    static if (hasIndirections!(typeof(s.cellAt(0).value)))
        foreach (i; 0 .. s.len)
        {
            auto c = s.cellAt(i);
            if (c.link == SLAB_LIVE) tuckDrop(c.value);
        }
    s.len = 0; s.freeHead = 0; s.live = 0;
}

/// At exit under `-version=tuckTrack`: hand the slab's own storage back, so
/// the report names what the PROGRAM leaked rather than the slab, which
/// lives until exit by design.
void tuckSlabRelease(S)(ref S s)
{
    version (tuckTrack)
    {
        tuckSlabReset(s);
        static if (__traits(hasMember, S, "top"))
        {
            foreach (pg; s.top)
            {
                if (pg is null) continue;
                foreach (ch; *pg) if (ch !is null) tuckFreeBlock(cast(void*) ch);
                tuckFreeBlock(cast(void*) pg);
            }
        }
        else static if (__traits(hasMember, S, "cells") && is(typeof(s.cells) == U[], U))
        {
            tuckFreeBlock(cast(void*) s.cells.ptr);
            s.cells = null;
        }
    }
}

long tuckSlabCount(S)(ref S s) { return s.live; }

/// An arena's `[size: N]` (slab proposal §9): the bytes its slabs may hold
/// between resets, charged per `new` by a size the COMPILER computed from
/// the Tuck type, so a budget runs out at the same `new` on every backend.
struct ArenaBudget { long size; long used; }

/// A cell of an arena's slab holding `v`, or absent when the budget cannot
/// cover it. The arena's reset gives the whole budget back.
TuckResult!SlabRef tuckArenaNew(T)(ref SlabChunked!T s, ref ArenaBudget b, long cost, T v)
{
    if (b.used + cost > b.size) return tnone!SlabRef();
    b.used += cost;
    return tok(tuckSlabNew(s, v));
}

/// At exit: say how many cells were never freed (slab proposal Q3).
void tuckSlabReport(S)(ref S s)
{
    import std.stdio : stderr;
    if (s.live > 0) stderr.writeln("TUCK SLAB [", s.name, "]: ", s.live, " cell(s) never freed");
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
        posixClose(fd);
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
                    posixClose(fd);
                    r.status = FsIoStatus.IoFailed;
                    return;
                }
                buf = bigger;
            }
            auto n = read(fd, cast(ubyte*) buf + len, cap - len);
            if (n < 0)
            {
                free(buf);
                posixClose(fd);
                r.status = FsIoStatus.IoFailed;
                return;
            }
            if (n == 0) break;
            len += n;
        }
        posixClose(fd);
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
string[] listDir(string path)
{
    import std.file : dirEntries, isDir, exists, SpanMode;
    import std.path : baseName;
    import std.algorithm : sort;
    string[] names;
    if (!exists(path) || !isDir(path)) return names;
    foreach (e; dirEntries(path, SpanMode.shallow)) names ~= baseName(e.name);
    sort(names);
    return names;
}

/// Runs `line` through the shell, output going where the program's own goes;
/// returns its exit code.
long runCommand(string line)
{
    import std.process : spawnShell, wait;
    return wait(spawnShell(line));
}

/// Runs `line` through the shell (popen) and answers its stdout and exit
/// status: the code it exited with, or 128 + N when signal N ended it. stderr
/// is not captured. The same in tuck_rt.nim and tuckrt/tuck_rt.odin.
R captureCommand(R)(string line)
{
    import core.stdc.stdio : FILE, fread;
    import core.sys.posix.stdio : popen, pclose;
    import std.string : toStringz;
    R r;
    FILE* f = popen(toStringz(line), "r");
    if (f is null) { r.code = 127; r.output = ""; return r; }
    char[4096] buf;
    string out_;
    for (;;)
    {
        auto n = fread(buf.ptr, 1, buf.length, f);
        if (n == 0) break;
        out_ ~= buf[0 .. n].idup;
    }
    immutable status = pclose(f);
    r.code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f);
    r.output = out_;
    return r;
}

bool fileExists(string path)
{
    import std.file : exists;
    return exists(path);
}

/// Idempotent by an explicit existence check, same as the Nim and Odin
/// runtimes, so all three backends agree on the same contract rather than
/// relying on each platform's own already-exists behavior for mkdir -p.
/// errno from a metadata call (stat, rename, rmdir) onto the FsError variants,
/// the same buckets in all three runtimes.
private ushort fsErrnoCode(int e)
{
    import core.stdc.errno : ENOENT, ENOTDIR, EACCES, EPERM, ENOTEMPTY, EEXIST;
    if (e == ENOENT || e == ENOTDIR) return errCode("fs/FsError.NotFound");
    if (e == EACCES || e == EPERM) return errCode("fs/FsError.AccessDenied");
    if (e == ENOTEMPTY || e == EEXIST) return errCode("fs/FsError.NotEmpty");
    return errCode("fs/FsError.IoFailed");
}

/// lstat: a final symbolic link is reported as a link, not followed. NOT
/// offloaded, same rationale as fileExists.
R pathInfo(R)(string path)
{
    import core.sys.posix.sys.stat : stat_t, lstat, S_ISDIR, S_ISLNK;
    import core.stdc.errno : errno;
    import std.string : toStringz;
    alias P = typeof(R.value);
    stat_t st;
    if (lstat(toStringz(path), &st) != 0) return terr!P(fsErrnoCode(errno));
    P p;
    p.isFolder = S_ISDIR(st.st_mode);
    p.isLink = S_ISLNK(st.st_mode);
    p.bytes = cast(long) st.st_size;
    p.modifiedMs = cast(long) st.st_mtim.tv_sec * 1000 + cast(long) st.st_mtim.tv_nsec / 1_000_000;
    return tok(p);
}

TuckResult!TuckUnit renamePath(string path, string to)
{
    import core.stdc.stdio : rename;
    import core.stdc.errno : errno;
    import std.string : toStringz;
    if (rename(toStringz(path), toStringz(to)) != 0)
        return terr!TuckUnit(fsErrnoCode(errno));
    return tokVoid();
}

TuckResult!TuckUnit removeFolder(string path)
{
    import core.sys.posix.unistd : rmdir;
    import core.stdc.errno : errno;
    import std.string : toStringz;
    if (rmdir(toStringz(path)) != 0) return terr!TuckUnit(fsErrnoCode(errno));
    return tokVoid();
}

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
    return tuckRec!(R, "total")(n);
}

R argAt(R)(long index)
{
    // 1-based like Nim's paramStr: 1..argCount are the arguments, 0 the program
    if (index < 0 || index >= cast(long) tuckArgs.length)
        return tuckRec!(R, "arg")("");
    return tuckRec!(R, "arg")(tuckArgs[cast(size_t) index]);
}

/// `?{value: str}` — an unset variable is ABSENT, not an error and not an
/// empty string. Absence is a first-class status, so the caller matches on
/// it rather than comparing against a sentinel.
// --- signals as values (std/sys) -----------------------------------------------
// One signalfd for the process: every watched signal is blocked for normal
// delivery and read from it instead, so receiving one is reading a descriptor
// the reactor can await.
private __gshared int gSigFd = -1;
private __gshared bool gSigInit = false;
private __gshared imported!"core.sys.posix.signal".sigset_t gSigMask;

void watchSignal(long number)
{
    import core.sys.posix.signal : sigemptyset, sigaddset, pthread_sigmask, SIG_BLOCK;
    import core.sys.linux.sys.signalfd : signalfd, SFD_NONBLOCK, SFD_CLOEXEC;
    if (!gSigInit) { sigemptyset(&gSigMask); gSigInit = true; }
    sigaddset(&gSigMask, cast(int) number);
    pthread_sigmask(SIG_BLOCK, &gSigMask, null);
    auto fd = signalfd(gSigFd, &gSigMask, SFD_NONBLOCK | SFD_CLOEXEC);
    if (fd >= 0) gSigFd = fd;
}

/// The next watched signal, or none after `timeoutMs`. In a task the wait
/// suspends only that task; in `main` it is a plain poll.
R nextSignal(R)(long timeoutMs)
{
    import core.sys.linux.sys.signalfd : signalfd_siginfo;
    import core.sys.posix.unistd : read;
    import core.stdc.errno : errno, EAGAIN, EWOULDBLOCK;
    alias P = typeof(R.value);
    if (gSigFd < 0) return tnone!P();
    signalfd_siginfo info;
    for (;;)
    {
        auto n = read(gSigFd, &info, info.sizeof);
        if (n == info.sizeof) return tok(tuckRec!(P, "number")(cast(long) info.ssi_signo));
        if (n >= 0 || (errno != EAGAIN && errno != EWOULDBLOCK)) return tnone!P();
        if (!tuckAwaitReadOrTimeout(gSigFd, timeoutMs)) return tnone!P();
    }
}

/// raise(3): to the calling thread, which is the one that blocked it.
void raiseSignal(long number)
{
    import core.stdc.signal : raise;
    raise(cast(int) number);
}

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
// std/random's one shim: the operating system's entropy, as 64 bits.
R osSeed(R)()
{
    import std.random : unpredictableSeed;
    ulong hi = unpredictableSeed;
    ulong lo = unpredictableSeed;
    return tuckRec!(R, "seed")((hi << 32) | lo);
}

// --- std/net — TCP over the reactor -----------------------------------------------
// The same shape as tuck_rt.nim's and tuck_rt.odin's: sockets are plain
// non-blocking fds, and every call that can wait suspends the CALLING task on
// readiness (tuckAwaitRead/Write) instead of blocking the thread. An empty
// recv means the peer closed cleanly. Renamed imports keep the POSIX names
// (`accept`, `send`, `close`...) from colliding with the externs below.
private static import sock = core.sys.posix.sys.socket;
private static import inet = core.sys.posix.netinet.in_;
private static import arpa = core.sys.posix.arpa.inet;
private static import fcntl_ = core.sys.posix.fcntl;
private static import errno_ = core.stdc.errno;

private enum NetErrKind { Refused, AddressInUse, Unreachable, Closed, IoFailed }

/// One place mapping an errno class onto the NetError variants declared in
/// std/net.tuck. Exhaustive, so a new kind is a compile error here.
private ushort netErrCode(NetErrKind k)
{
    final switch (k)
    {
    case NetErrKind.Refused:      return errCode("net/NetError.Refused");
    case NetErrKind.AddressInUse: return errCode("net/NetError.AddressInUse");
    case NetErrKind.Unreachable:  return errCode("net/NetError.Unreachable");
    case NetErrKind.Closed:       return errCode("net/NetError.Closed");
    case NetErrKind.IoFailed:     return errCode("net/NetError.IoFailed");
    }
}

/// errno at the moment of failure, bucketed into what a Tuck program can act
/// on. Anything unrecognised is IoFailed rather than a guess.
private ushort netErrnoCode(int e)
{
    with (errno_)
    {
        if (e == ECONNREFUSED) return netErrCode(NetErrKind.Refused);
        if (e == EADDRINUSE) return netErrCode(NetErrKind.AddressInUse);
        if (e == ENETUNREACH || e == EHOSTUNREACH)
            return netErrCode(NetErrKind.Unreachable);
        if (e == EPIPE || e == ECONNRESET) return netErrCode(NetErrKind.Closed);
    }
    return netErrCode(NetErrKind.IoFailed);
}

private void setNonBlocking(int fd)
{
    auto fl = fcntl_.fcntl(fd, fcntl_.F_GETFL, 0);
    fcntl_.fcntl(fd, fcntl_.F_SETFL, fl | fcntl_.O_NONBLOCK);
}

/// A non-blocking TCP socket listening on all interfaces at `port`
/// (SO_REUSEADDR set, backlog 64), or the classified errno.
R listen(R)(long port)
{
    alias P = typeof(R.value);
    int fd = sock.socket(sock.AF_INET, sock.SOCK_STREAM, 0);
    if (fd < 0) return terr!P(netErrnoCode(errno_.errno));
    // SO_REUSEADDR so a restarted server does not trip over its own TIME_WAIT
    // sockets - without it, rebinding within ~60s of a shutdown fails.
    int yes = 1;
    sock.setsockopt(fd, sock.SOL_SOCKET, sock.SO_REUSEADDR, &yes, yes.sizeof);
    inet.sockaddr_in sa;
    sa.sin_family = cast(ushort) sock.AF_INET;
    sa.sin_port = arpa.htons(cast(ushort) port);
    sa.sin_addr.s_addr = inet.INADDR_ANY;
    if (sock.bind(fd, cast(sock.sockaddr*) &sa, sa.sizeof) < 0)
    {
        auto e = errno_.errno;
        posixClose(fd);
        return terr!P(netErrnoCode(e));
    }
    if (sock.listen(fd, 64) < 0)
    {
        auto e = errno_.errno;
        posixClose(fd);
        return terr!P(netErrnoCode(e));
    }
    setNonBlocking(fd);
    return tok(tuckRec!(P, "fd")(cast(long) fd));
}

/// Suspends on the listening fd until a client arrives. Re-parks on a spurious
/// wake (another coroutine took the connection first).
R accept(R)(long fd)
{
    alias P = typeof(R.value);
    for (;;)
    {
        tuckAwaitRead(fd);
        int c = sock.accept(cast(int) fd, null, null);
        if (c >= 0)
        {
            setNonBlocking(c);
            return tok(tuckRec!(P, "fd")(cast(long) c));
        }
        auto e = errno_.errno;
        if (e != errno_.EAGAIN && e != errno_.EWOULDBLOCK)
            return terr!P(netErrnoCode(e));
    }
}

/// Non-blocking connect: the syscall returns EINPROGRESS immediately and the fd
/// becomes WRITABLE when the handshake finishes, so the task suspends on
/// write-readiness. Only dotted-quad hosts: a hostname needs DNS, which blocks.
R connect(R)(string host, long port)
{
    import std.string : toStringz;
    alias P = typeof(R.value);
    inet.sockaddr_in sa;
    sa.sin_family = cast(ushort) sock.AF_INET;
    sa.sin_port = arpa.htons(cast(ushort) port);
    sa.sin_addr.s_addr = arpa.inet_addr(toStringz(host));
    if (sa.sin_addr.s_addr == uint.max && host != "255.255.255.255")
        return terr!P(netErrCode(NetErrKind.Unreachable));
    int fd = sock.socket(sock.AF_INET, sock.SOCK_STREAM, 0);
    if (fd < 0) return terr!P(netErrnoCode(errno_.errno));
    setNonBlocking(fd);
    if (sock.connect(fd, cast(sock.sockaddr*) &sa, sa.sizeof) < 0)
    {
        auto e = errno_.errno;
        if (e != errno_.EINPROGRESS)
        {
            posixClose(fd);
            return terr!P(netErrnoCode(e));
        }
        tuckAwaitWrite(fd);
        // The handshake's real outcome lands in SO_ERROR, not in connect's return.
        int soErr = 0;
        uint sl = soErr.sizeof;
        sock.getsockopt(fd, sock.SOL_SOCKET, sock.SO_ERROR, &soErr, &sl);
        if (soErr != 0)
        {
            posixClose(fd);
            return terr!P(netErrnoCode(soErr));
        }
    }
    return tok(tuckRec!(P, "fd")(cast(long) fd));
}

/// An EMPTY result means the peer closed cleanly - not an error, so callers
/// test `.data.length == 0` rather than matching a variant.
R recv(R)(long fd, long max)
{
    alias P = typeof(R.value);
    if (max <= 0) return tok(tuckRec!(P, "data")(""));
    auto buf = new char[cast(size_t) max];
    for (;;)
    {
        tuckAwaitRead(fd);
        auto n = sock.recv(cast(int) fd, buf.ptr, buf.length, 0);
        if (n > 0) return tok(tuckRec!(P, "data")(buf[0 .. n].idup));
        if (n == 0) return tok(tuckRec!(P, "data")(""));
        auto e = errno_.errno;
        if (e != errno_.EAGAIN && e != errno_.EWOULDBLOCK)
            return terr!P(netErrnoCode(e));
    }
}

/// Sends ALL of it, suspending on write-readiness whenever the kernel buffer
/// fills. A partial write is not surfaced: the caller asked to send a value.
R send(R)(long fd, string data)
{
    alias P = typeof(R.value);
    size_t sent = 0;
    while (sent < data.length)
    {
        auto n = sock.send(cast(int) fd, data.ptr + sent, data.length - sent,
                           sock.MSG_NOSIGNAL);
        if (n > 0) sent += n;
        else
        {
            auto e = errno_.errno;
            if (e == errno_.EAGAIN || e == errno_.EWOULDBLOCK) tuckAwaitWrite(fd);
            else return terr!P(netErrnoCode(e));
        }
    }
    return tok(tuckRec!(P, "sent")(cast(long) sent));
}

/// Closes an fd. Errors are ignored: there is nothing a caller can do.
void close(long fd)
{
    posixClose(cast(int) fd);
}

R nowMs(R)()
{
    import std.datetime.systime : Clock;
    return tuckRec!(R, "epochMs")(
        cast(ulong)(Clock.currStdTime / 10_000 - 62_135_596_800_000L));
}

/// The reactor's timer: a task's sleep suspends only that task, and main's
/// runs the scheduler for the duration (tuckSleep).
void sleepMs(uint ms)
{
    tuckSleep(ms);
}

// --- a demo async source -----------------------------------------------
// A REAL non-blocking source: a one-shot timerfd, readable once `ms` passes,
// so a task racing `read fd` against `timeout N` sees the true winner. It has
// no helper coroutine — that held `tuckRun` open past a fired timeout (A16).
// Mirrors tuck_async.nim's openSource and tuckrt/tuck_coro.odin's openSource —
// the runtimes must agree on what "async" means, or a program's behaviour
// would depend on which backend built it.
R openSource(R)(long ms)
{
    return tuckRec!(R, "fd")(cast(long) tuckTimerSource(ms));
}
