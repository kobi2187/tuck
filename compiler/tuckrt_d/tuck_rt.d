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
import std.conv : text;

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

/// An invariant violation (spec 4.7) — abort naming the condition.
///
/// NOT `assert`: dmd's `-release` strips asserts outright, so a guard built
/// on one silently evaporates in exactly the build where a violated
/// invariant means corrupt data. ROADMAP's 2026-08-25 ruling 5 says
/// invariants stay on in release by default, opt-out only, so the check has
/// to be real code the optimiser keeps. (The Nim backend has the same bug
/// from the other direction: it hardcodes `when not defined(release)`.)
void tuckInvariantFailed(string cond, string typeName)
{
    import std.stdio : stderr;
    import core.stdc.stdlib : abort;
    stderr.writeln("Invariant violated on ", typeName, ": ", cond);
    abort();
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

T at(T)(T[] items, long index)
{
    tuckSeqBounds(index, cast(long) items.length, "at");
    return items[index];
}

void setAt(T)(ref T[] items, long index, T value)
{
    tuckSeqBounds(index, cast(long) items.length, "setAt");
    items[index] = value;
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

// std/fs — the filesystem. The error codes are the FsError variants the
// Tuck declaration names, hashed the same way every backend hashes them.
//
// Blocking calls, deliberately for now: the Nim runtime offloads these to a
// worker so other coroutines keep running, and this must do the same once
// the coroutine runtime lands (portable runtime CHARACTERISTICS, not just
// semantics). Single-task programs cannot tell the difference yet.
R readFile(R)(string path)
{
    import std.file : exists, read, FileException;
    alias P = typeof(R.value);
    if (!exists(path))
        return terr!P(errCode("fs/FsError.NotFound"));
    try
        return tok(tuckRec!(P, "content")(cast(string) read(path)));
    catch (Exception)
        return terr!P(errCode("fs/FsError.IoFailed"));
}

TuckResult!TuckUnit writeFile(string path, string content)
{
    import std.file : write;
    try
    {
        write(path, content);
        return tokVoid();
    }
    catch (Exception)
        return terr!TuckUnit(errCode("fs/FsError.IoFailed"));
}

/// NOT a result: a stat that says "no" is an answer, not a failure — the
/// Tuck declaration returns a plain bool and the Nim runtime agrees.
bool fileExists(string path)
{
    import std.file : exists;
    return exists(path);
}

TuckResult!TuckUnit removeFile(string path)
{
    import std.file : remove, exists;
    if (!exists(path))
        return terr!TuckUnit(errCode("fs/FsError.NotFound"));
    try
    {
        remove(path);
        return tokVoid();
    }
    catch (Exception)
        return terr!TuckUnit(errCode("fs/FsError.IoFailed"));
}

TuckResult!TuckUnit appendFile(string path, string content)
{
    import std.file : append;
    try
    {
        append(path, content);
        return tokVoid();
    }
    catch (Exception)
        return terr!TuckUnit(errCode("fs/FsError.IoFailed"));
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
