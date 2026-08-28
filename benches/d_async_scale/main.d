// Bench 1 — async runtime scale, D backend.
//
// The D twin of benches/bench_async_scale.nim and benches/odin_async_scale.
// Same N, same K, same two metrics, so the three are directly comparable.
//
// All three backends drive the SAME vendored minicoro, so this is not a
// language shootout: it checks that the D port carries the engine's
// characteristics across. A large gap against the Nim and Odin rows in
// SCORES.md means a porting bug, not a language difference.
//
// Build: dmd -O -release -inline -i -I<tuckrt_d> main.d minicoro.a
module main;

import rt = tuck_coro;
import std.stdio : writeln, writefln;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.conv : to;

void main(string[] args)
{
    // Same ceiling note as the Nim bench: each coroutine owns its own
    // minicoro stack, so N live coroutines reserve N * stack. Spawn cost is
    // dominated by that allocation, not by scheduler enqueue; switch
    // throughput is the headline number.
    int n = args.length >= 2 ? args[1].to!int : 10_000;
    int k = args.length >= 3 ? args[2].to!int : 100;

    rt.tuckAsyncInit();

    // --- spawn throughput ---
    // NOT `shared`: the scheduler is cooperative on ONE thread (spec §9.4),
    // so an atomic here would measure synchronisation the runtime never
    // performs.
    int done = 0;
    auto swSpawn = StopWatch(AutoStart.yes);
    foreach (i; 0 .. n)
    {
        rt.tuckSpawn({
            foreach (_; 0 .. k)
                rt.tuckYield();
            done++;
        });
    }
    swSpawn.stop();
    double tSpawn = swSpawn.peek.total!"usecs" / 1_000_000.0;

    // --- drive to completion; time the switch storm ---
    auto swRun = StopWatch(AutoStart.yes);
    rt.tuckRun();
    swRun.stop();
    double tRun = swRun.peek.total!"usecs" / 1_000_000.0;

    assert(done == n, "only " ~ done.to!string ~ "/" ~ n.to!string ~
           " coroutines finished");

    double switches = cast(double) n * (k + 1);  // k yields + 1 final schedule
    writeln("async scale: N=", n, " K=", k);
    writefln("  spawn:   %d coros in %.1f ms  = %.2f M coros/sec",
             n, tSpawn * 1000, n / tSpawn / 1e6);
    writefln("  run:     %d switches in %.1f ms  = %.2f M switches/sec",
             cast(long) switches, tRun * 1000, switches / tRun / 1e6);
}
