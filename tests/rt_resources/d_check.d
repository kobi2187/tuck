/// The registry's SEMANTICS, asserted against the D runtime. The twin of
/// tests/rt_resources/nim_check.nim and odin/main.odin: the identical list in
/// all three, which is the point — three runtimes, one behaviour.
///
/// tests/suites/resources_rt.nim compiles this beside compiler/tuckrt_d.
module d_check;

import std.stdio;
import rt = tuck_rt;

long[] closed;
long[] flushed;
void onClose(long r) { closed ~= r; }
void onFinish(long r) { flushed ~= r; }

int failures = 0;
void check(string name, bool cond)
{
    if (cond) writeln("  PASS  ", name);
    else { writeln("  FAIL  ", name); failures++; }
}

int main()
{
    rt.ResourceTable files;
    rt.initResourceTable(files, "file", 8, rt.RtResourcePolicy.Strict, 0);
    rt.setResourceHooks(files, &onFinish, &onClose);
    auto h1 = rt.acquireResource(files, 100L, "a.tuck:3");
    check("acquire succeeds", h1.status == rt.TuckStatus.Ok);
    check("deref reaches the OS handle", rt.derefResource(files, h1.value) == 100L);
    check("an unfinished entry is open", rt.openResourceCount(files) == 1);
    rt.finishResource(files, h1.value);
    check("strict: on_finish ran at the mark", flushed == [100L]);
    check("strict: the handle closed at the mark", closed == [100L]);
    check("strict: nothing is left open", rt.openResourceCount(files) == 0);

    closed = []; flushed = [];
    rt.ResourceTable net;
    rt.initResourceTable(net, "net", 4, rt.RtResourcePolicy.Lazy, 0);
    rt.setResourceHooks(net, &onFinish, &onClose);
    rt.ResourceHandle[] hs;
    foreach (i; 0 .. 4) hs ~= rt.acquireResource(net, cast(long) i, "x").value;
    check("a capped table fills to its cap", rt.openResourceCount(net) == 4);
    check("...and then reports absence, not an error",
          rt.acquireResource(net, 99L, "x").status == rt.TuckStatus.Absent);
    rt.finishResource(net, hs[0]);
    check("lazy: on_finish ran at the mark", flushed == [0L]);
    check("lazy: but nothing closed yet (1 of 4 is under the watermark)",
          closed.length == 0);
    rt.finishResource(net, hs[1]);
    rt.finishResource(net, hs[2]);
    check("lazy: the ~75% watermark (3 of 4) swept INLINE, inside the mark",
          closed.length == 3);

    closed = []; flushed = [];
    rt.ResourceTable socks;
    rt.initResourceTable(socks, "sock", 0, rt.RtResourcePolicy.Exit, 0);
    rt.setResourceHooks(socks, &onFinish, &onClose);
    auto a = rt.acquireResource(socks, 1L, "s1").value;
    rt.acquireResource(socks, 2L, "s2");
    rt.acquireResource(socks, 3L, "s3");
    check("an uncapped table grows past any fixed size", socks.entries.length == 3);
    rt.finishResource(socks, a);
    check("exit: the mark closes nothing", closed.length == 0);
    rt.closeAllResources(socks);
    check("exit: close-all runs LIFO in REGISTRATION order", closed == [3L, 2L, 1L]);
    check("...and flushes only what was never finished", flushed == [1L, 3L, 2L]);

    rt.ResourceTable t2;
    rt.initResourceTable(t2, "k", 2, rt.RtResourcePolicy.Exit, 0);
    auto x = rt.acquireResource(t2, 7L, "q").value;
    rt.finishResource(t2, x);
    check("the generation moves on AT THE MARK, so the handle dies there",
          t2.entries[x.slot].gen != x.gen);

    // What lets every backend emit the declaration as a static initializer
    // with no start-up code: the runtime sizes a capped table on first use.
    rt.ResourceTable lit = {kind: "lit", cap: 2, policy: rt.RtResourcePolicy.Exit,
                            sweepBatch: 0};
    check("a table built as a plain literal sizes itself on first acquire",
          rt.acquireResource(lit, 5L, "l").status == rt.TuckStatus.Ok);
    check("...and still honours its cap",
          rt.acquireResource(lit, 6L, "l").status == rt.TuckStatus.Ok &&
          rt.acquireResource(lit, 7L, "l").status == rt.TuckStatus.Absent);

    rt.ResourceTable rep;
    rt.initResourceTable(rep, "file", 4, rt.RtResourcePolicy.Exit, 0);
    auto k1 = rt.acquireResource(rep, 1L, "main.tuck:4").value;
    rt.acquireResource(rep, 2L, "main.tuck:9");
    rt.finishResource(rep, k1);
    check("the report lists only what was never finished, with its site",
          rt.openResourceCount(rep) == 1);

    return failures > 0 ? 1 : 0;
}
