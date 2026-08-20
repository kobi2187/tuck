# std.testing

## Purpose
An in-box test, benchmark, and fuzz runner with table-driven assertions, requiring no external framework and no I/O to exercise pure logic in isolation.

## Design lineage
Modeled directly on Go's `testing` package (including its built-in fuzzing since 1.18: `func FuzzX(f *testing.F)`), for the "one framework, zero install, benchmarks and fuzzing are first-class not bolted-on" shape, plus Zig's `std.testing` for its minimal assertion surface (`expectEqual`, `expectError`) that avoids the sprawling assertion-method zoo of xUnit-style frameworks.

## Proposed API
```
// Discovery: any fn matching the signature below, in a #[test]-tagged module, is a test.
type TestFn = fn(&mut T) -> core::types::Result<(), core::error::Error>;

struct T;  // per-test handle: logging, subtests, cleanup, skip
impl T {
    fn fail(&mut self, msg: &str);
    fn fatal(&mut self, msg: &str) -> !;           // fail + stop this test immediately
    fn skip(&mut self, reason: &str) -> !;
    fn log(&mut self, msg: &str);
    fn run(&mut self, name: &str, f: impl FnOnce(&mut T)); // named subtest, own pass/fail
    fn cleanup(&mut self, f: impl FnOnce() + 'static);      // LIFO, runs even if test panics
    fn temp_dir(&mut self) -> sys::fs::Path;                // auto-removed on cleanup
}

fn expect_eq<A: core::cmp::Eq + core::fmt::Debug>(t: &mut T, got: A, want: A);
fn expect_err<E>(t: &mut T, result: core::types::Result<impl core::fmt::Debug, E>);

// Table-driven helper: one case struct, one closure, per-case subtest + name.
fn table<Case>(t: &mut T, cases: &[Case], f: impl Fn(&mut T, &Case));

// Benchmarking
struct B;
impl B {
    fn reset_timer(&mut self);
    fn n(&self) -> u64;                 // iterations the runner has decided to run
}
type BenchFn = fn(&mut B);

// Fuzzing: runner supplies structured random input via Unstructured, corpus persisted under testdata/
struct Unstructured<'a>;
impl<'a> Unstructured<'a> {
    fn u8(&mut self) -> u8;
    fn bytes(&mut self, max_len: usize) -> &[u8];
    fn string(&mut self, max_len: usize) -> alloc::string::String;
}
type FuzzFn = fn(&mut T, &mut Unstructured);
fn fuzz_seed(t: &mut T, corpus: &[&[u8]]);  // seed corpus entries, replayed as regular test cases too

// CLI-invocable, but importantly also programmatically invocable — see "Validated by applications"
fn run_tests(pattern: Option<&str>) -> TestReport;
fn run_benchmarks(pattern: Option<&str>) -> BenchReport;
fn run_fuzz(target: &str, duration: core::types::Duration) -> FuzzReport;

// Added for kv-store-server: fault injection / crash simulation, for asserting durability
// properties ("kill mid-write, replay the WAL, no lost or corrupted acknowledged write") that
// pure-logic table/fuzz tests structurally cannot exercise — see "Revision (kv-store-server)".
mod fault {
    // True OS-level crash: `bin` is actually spawned as a subprocess (via sys.process, so real
    // page-cache/fsync/buffering behavior is in play, not a simulation of it) and killed
    // (SIGKILL, not SIGTERM — an unclean death is the whole point) once `trigger` fires. Returns
    // control to the test with the child gone so it can inspect on-disk state and run recovery.
    fn kill_subprocess(t: &mut T, bin: &str, args: &[&str], trigger: KillTrigger) -> sys::process::ExitStatus;
    enum KillTrigger {
        AfterDuration(core::types::Duration),          // coarse: "however far it got in N ms"
        AfterMarkerFile(sys::fs::Path),                 // precise: child writes/touches this path
                                                          // right after the write call under test,
                                                          // before its own next step — the marker
                                                          // acts as a synchronization point so the
                                                          // kill lands at a known point in the child's
                                                          // write sequence, not a racy wall-clock guess
    }

    // Lighter-weight, in-process variant for narrower cases that don't need a real process
    // boundary (e.g. "the 3rd sys.io::Writer::write call returns a short write" or "this read
    // comes back corrupted") — an injected fault surfaces as a normal core::error::Error at the
    // call site, not a process death, so it composes with ordinary Result-based test assertions.
    struct Injector;
    impl Injector {
        fn new() -> Injector;
        fn fail_nth_write(&mut self, n: u64, err: core::error::Error);
        fn corrupt_nth_read(&mut self, n: u64, corruption: impl FnOnce(&mut [u8]) + 'static);
    }
    fn with_injector<R>(t: &mut T, inj: Injector, f: impl FnOnce(&mut T) -> R) -> R;
}
```

## Key design decisions
- **No mocking framework, no dependency-injection container** — `T::cleanup` and plain function parameters (accept `sys.io::Reader`/`Writer` interfaces instead of concrete file handles) are considered sufficient, matching Go's philosophy that if your code needs a mocking framework to test, the seam is in the wrong place.
- **Subtests (`T::run`) are the unit of isolation**, not separate files/classes — a table-driven test is a single `TestFn` that fans out into named subtests, each independently pass/fail/skippable and independently re-runnable via `-run TestName/subtest_name` pattern matching.
- **Fuzzing shares the assertion surface with normal tests** (`FuzzFn` takes the same `&mut T`) rather than being a separate DSL, so a fuzz failure minimizes to a regular seed-corpus test case with zero translation.
- Benchmarks explicitly do **not** auto-parallelize by default (unlike some frameworks) — `B` exposes `n()` and `reset_timer()` only, keeping the timing model simple and avoiding hidden contention skewing results.
- **`run_fuzz` minimizes a failing input before reporting it.** Once a `FuzzFn` fails, the runner replays smaller/simpler byte buffers that still reproduce the failure (shrinking the underlying `Unstructured` source toward empty/simpler, the same mechanism cargo-fuzz's `arbitrary` crate and Go's `testing.F` both use) and reports the smallest one found, rather than whatever full-size random input happened to trigger the bug first. This was implicit in `doc-convert-tester`'s fuzz validation but never actually stated as a behavior of `run_fuzz` until `diff-patch` made the gap concrete: a random multi-kilobyte failing text pair is not a usable bug report for a diff/patch mismatch, and the design was previously silent on whether the runner does anything besides replay the seed corpus. Shrinking operates generically on the byte buffer `Unstructured` draws from — it has no need to understand that a target calls `u.string()` twice to build a text pair, so this requires no new API surface beyond documenting `run_fuzz`'s existing behavior.
- **Revision (kv-store-server):** every prior validating app (`cli-hangman` through `archive-cli`) tests pure logic or, at most, real files reached through `T::temp_dir`/`T::cleanup` — none of them needs the program under test to actually die mid-operation. `kv-store-server`'s crash-recovery correctness ("kill the process mid-write, replay the WAL, assert no lost or corrupted acknowledged write") is not expressible with `table`/`expect_eq`/`fuzz` at all: those assert on values a running process hands back, and the property under test here is specifically about what's true on disk *after* the process no longer exists to hand anything back. The `fault` module above is the concrete addition: `fault::kill_subprocess` is the primary, load-bearing mechanism (a real `SIGKILL` against a real subprocess, so `sys.fs`'s fsync/buffering guarantees are actually being tested rather than assumed), with `fault::Injector`/`with_injector` offered for narrower single-process cases (a short write, a corrupted read) that don't need the cost and realism of an actual process boundary. `KillTrigger::AfterMarkerFile` exists because `AfterDuration` alone would make "kill exactly after the Nth WAL append, before its fsync completes" a timing-dependent guess rather than a repeatable test.

## Validated by applications
- **cli-hangman**: the explicit design target for "pure logic tested in total isolation from I/O." The game state machine (`guess(state, letter) -> state`) takes and returns plain values with no `sys.cli`/`sys.fs` dependency, so its test module is `table(t, &cases, |t, c| expect_eq(t, guess(c.state, c.letter), c.want))` with zero fakes or mocks required — confirms the module doesn't force ceremony onto trivial programs (this app is deliberately the smallest in the set, a control case).
- **doc-convert-tester**: the primary fuzz/property-testing consumer — `FuzzFn` targets feed a decoded document through `A -> B -> A` round-trip conversion and assert the diff is empty (or explicitly flagged lossy), directly exercising `Unstructured::string` to generate random-but-valid Unicode text including combining sequences and BOM edge cases, which forced `Unstructured` to expose a `string()` helper distinct from raw `bytes()` rather than making every fuzz target hand-roll UTF-8 validity.
- **todo-cli**: uses `table` exhaustively for the filter-query parser and recurrence-rule math ("next occurrence after date D" for every weekday/interval combination) — a case list large enough (dozens of date/rule pairs) that named subtests (not just pass/fail counts) were necessary to make failures diagnosable, validating `T::run`'s per-case naming.
- **archive-cli**: uses `T::temp_dir` and `T::cleanup` heavily to create/extract real archives to a scratch directory per test without manual teardown bookkeeping, and `expect_err` to assert specific corruption/wrong-password failure modes rather than only "it errored."
- **kv-store-server**: the originating case for the `fault` module above — see "Revision (kv-store-server)". A representative test: seed a WAL, `fault::kill_subprocess` a child that's mid-`SET` at a marker-file checkpoint right after the append but before its fsync would be guaranteed durable, then in the parent process replay the WAL against a fresh in-memory map and assert the recovered state is exactly "every acknowledged write present, nothing corrupted, the unacknowledged in-flight write is either fully present or fully absent, never a torn half-write."
- **math-toolkit-cli**: the app's own profile frames exact-arithmetic correctness as needing property tests rather than only example-based ones — `table`-driven cases cover known rounding edge cases (`.005` under `HalfEven` vs. `HalfUp`), while a property-style test (fed via `Unstructured` and the existing fuzz machinery, no new `std.testing` surface required) checks `convert(convert(x, A, B), B, A) == x` within epsilon and that repeated `Decimal` addition never silently loses a cent — confirming the fuzzing surface designed for `doc-convert-tester`'s round-trip harness generalizes cleanly to a second app's round-trip property with no changes needed here.
- **sudoku-solver**: a clean property-testing citation, no new API needed. The generator's correctness is naturally two composed properties rather than one fixed expected output per case (there is no single "correct" generated puzzle to `expect_eq` against): `table`/`expect_eq` style example-based tests cover the solver against a fixed set of known puzzles with known solutions, while the generator's own guarantee — `solve(generate(difficulty)).is_some()` (every generated puzzle is solvable at all) and uniqueness (removing the next cell during generation is only accepted if the puzzle still has exactly one solution) — is exactly the kind of invariant-over-many-random-instances `run_fuzz`/`Unstructured`-driven property testing (already validated by `doc-convert-tester`'s round-trip and `math-toolkit-cli`'s `convert(convert(x))==x` properties) is suited for: generate N puzzles via `Unstructured`-seeded randomization of `std.random`'s cell-removal order, and assert both properties hold for every one, with a failing seed shrinking (per `run_fuzz`'s existing behavior) toward the smallest reproducing case. No new `std.testing` surface is needed — this is a second confirmation, after `math-toolkit-cli`, that the fuzz/property machinery built for `doc-convert-tester` generalizes to a domain with no text-round-trip framing at all.
- **backup-sync**: another clean property-testing citation, no new API needed. `--delta` mode's core correctness claim — reconstructing the new file from the old file plus the transferred delta blocks reproduces the new file exactly, byte for byte — is a round-trip property in the same shape `doc-convert-tester` and `diff-patch` already validate (`apply(diff(a, b), a) == b`, here `reconstruct(old, delta(old, new)) == new`), generated via two independent `Unstructured::bytes` buffers standing in for old/new file contents rather than the text-specific `Unstructured::string` `diff-patch` uses, confirming the generator surface is reusable for binary data, not just Unicode text. `T::temp_dir`/`T::cleanup` (already validated by `archive-cli`) cover the `--dry-run`/atomic-replace tests, which need real files on disk rather than in-memory buffers to assert "an interrupted sync never leaves a half-written destination file."
- **diff-patch**: `std.testing`'s best property-testing case yet, and the forcing case for documenting `run_fuzz`'s shrinking behavior above. `apply(diff(a, b), a) == b` is checked for `a, b` each generated via `Unstructured::string(max_len)` — two independent calls, not a correlated-pair generator, because the property must hold for arbitrary, even unrelated, text pairs (a large, mostly-irrelevant diff is still a *correct* diff), so no new generator primitive beyond what `doc-convert-tester` already validated for single-string generation is needed. What this app newly exposes is not a generation gap but a reporting one: an unshrunk failing case here is two multi-kilobyte random strings, which is useless for isolating a real Myers-diff bug — confirming shrinking (not richer generators) was the actual missing piece for structured/textual fuzz targets, as opposed to the simpler numeric fault-injection scenarios (`kv-store-server`) validated so far, where a small counterexample is more likely to occur naturally without minimization.

## Open questions / risks
- Whether benchmark results should be captured in a structured, machine-comparable format in the box (for regression-gating in CI) or left as text output for external tooling to parse is unresolved; Go leaves this to `benchstat` as a separate tool, which this design currently mirrors rather than improves on.
- The shrink strategy itself (shrink toward shorter length first vs. toward simpler byte/codepoint values first, and whether `Unstructured::string`'s shrinker is UTF-8-boundary-aware so a shrunk buffer can't produce invalid text) is unspecified beyond "toward empty/simpler" above; `diff-patch` validates that shrinking needs to exist at all, not what a good shrink ordering looks like for text specifically — a concrete open question for the next app that depends on shrink *quality*, not just shrink *presence*.
