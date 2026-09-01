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
import core.sys.posix.unistd : pipe2, read, write, close;

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

/// An actor's mailbox: a fixed-capacity ring, sized at compile time (spec
/// 9.1) so it is a known footprint rather than an unbounded allocation.
///
/// No lock, deliberately: the scheduler is cooperative on ONE thread, so
/// sends and drains never interleave. (The Nim runtime guards its mailbox
/// because a blocking extern can send from the offload worker; if D gains
/// that path, this needs the same guard.)
struct Mailbox(T, size_t Cap)
{
    T[Cap] data;
    size_t head;
    size_t tail;
}

/// Returns false when the ring is FULL — the message is dropped.
///
/// That is the existing de-facto behaviour of the Nim runtime, matched here
/// deliberately rather than improved on: the spec states no full-mailbox
/// policy (FRICTIONS.md #9), so choosing one is a language decision, not a
/// backend's. Verified consequence, recorded in the actor playground: a
/// waitUntil whose predicate needs the dropped messages spins forever, on
/// the Nim backend too.
bool enqueue(T, size_t Cap)(ref Mailbox!(T, Cap) mb, T msg)
{
    size_t next = (mb.tail + 1) % Cap;
    if (next == mb.head) return false;
    mb.data[mb.tail] = msg;
    mb.tail = next;
    return true;
}

bool dequeue(T, size_t Cap)(ref Mailbox!(T, Cap) mb, ref T msg)
{
    if (mb.head == mb.tail) return false;
    msg = mb.data[mb.head];
    mb.head = (mb.head + 1) % Cap;
    return true;
}

bool hasRoom(T, size_t Cap)(ref Mailbox!(T, Cap) mb)
{
    return ((mb.tail + 1) % Cap) != mb.head;
}

void initMailbox(T, size_t Cap)(ref Mailbox!(T, Cap) mb) {}  // nothing to do

/// A fixed-count object pool (spec 7.2). N slots decided at compile time, so
/// the footprint is static — that is the whole point of the declaration.
///
/// `acquire` returns `?T`: exhaustion is ABSENCE, not an error. A count is a
/// real-world fact and running out is backpressure, so the caller matches on
/// it rather than handling a failure.
struct ObjectPool(T, size_t Count)
{
    T[Count] storage;
    ulong occupied;   /// ponytail: 64 slots max, matching the Odin runtime;
                      /// widen to an array of words if a program needs more.
}

TuckResult!T acquire(T, size_t Count)(ref ObjectPool!(T, Count) pool)
{
    foreach (i; 0 .. Count)
    {
        if ((pool.occupied & (1UL << i)) == 0)
        {
            pool.occupied |= 1UL << i;
            return tok(pool.storage[i]);
        }
    }
    return tnone!T();
}

void release(T, size_t Count)(ref ObjectPool!(T, Count) pool, T item)
{
    // Which slot did this come from? The value was handed out from one of
    // these cells, so match it back by equality — same rule as the Odin
    // runtime, so a program behaves identically on either backend.
    foreach (i; 0 .. Count)
    {
        if (pool.storage[i] == item)
        {
            pool.occupied &= ~(1UL << i);
            return;
        }
    }
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
