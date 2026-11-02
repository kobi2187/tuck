# The Benchmarks Game, in Tuck

The programs of the Computer Language Benchmarks Game
(<https://benchmarksgame-team.pages.debian.net/benchmarksgame/>), written as
Tuck is meant to be written: values, `Seq`s, small fns, no tricks. Each one is
written here from the algorithm's definition, beside a plain C version of the
same algorithm that serves as the reference for both the output and the time.

**The rule: the programs are not tuned.** When one is slow, the fix goes into
the compiler — a lowering, a deduction, a runtime primitive, a build flag — so
every Tuck program gets faster, not just the benchmark. A program changes only
when it is not idiomatic, or when it hits a gap in the language or stdlib
(which is then fixed, and the program written the natural way).

    benches/game/run.sh            # build on Nim, Odin and D; check; time
    benches/game/run.sh nbody      # one program

Times are best of three, in release mode, against `gcc -O2`. The ledger of
what each compiler change bought is `benches/SCORES.md`, "Benchmarks Game".
