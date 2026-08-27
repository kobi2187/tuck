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

// std/console — terminal I/O (rt-implemented externs).
void print(string s) { stdout.write(s); stdout.flush(); }
void printLine(string s) { stdout.writeln(s); }

// `toStr` — the universal stringifier. tuck_rt.nim spells it `$value`; D's
// std.conv.text is the same "any value to its display form" operation.
string toStr(T)(T value) { return text(value); }

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

// std/sys — process control.
void exit(long code)
{
    import core.stdc.stdlib : cexit = exit;
    cexit(cast(int) code);
}

// std/time — sleepMs suspends the caller. Until the Fiber runtime lands
// there are no tasks to keep running, so a blocking sleep IS the reactor
// semantics for a single-task program.
void sleepMs(uint ms)
{
    import core.thread : Thread;
    import core.time : msecs;
    Thread.sleep(msecs(ms));
}
