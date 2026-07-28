// benches/odin_async_scale/main.odin
//
// The Odin twin of benches/bench_async_scale.nim: spawn N coroutines, each
// yields K times, then finishes. Same workload, same reported numbers.
//
// Both backends drive the SAME vendored minicoro (compiler/vendor/minicoro),
// so this is not a language comparison — it is a check that the Odin port
// carries the engine's characteristics across. A large gap means a porting
// bug. Differences that ARE expected: no GC write barriers, no ARC, and no
// stack-walker constraint on the Odin side.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
import rt "../../compiler/tuckrt"

n: int
k: int
done: int

body :: proc() {
	for _ in 0 ..< k {
		rt.tuckYield()
	}
	done += 1
}

main :: proc() {
	n = 10_000
	k = 100
	if len(os.args) >= 2 do n, _ = strconv.parse_int(os.args[1])
	if len(os.args) >= 3 do k, _ = strconv.parse_int(os.args[2])

	rt.tuckAsyncInit()

	// --- spawn throughput ---
	tSpawn0 := time.now()
	for _ in 0 ..< n {
		rt.tuckSpawn(body)
	}
	tSpawn := time.duration_seconds(time.since(tSpawn0))

	// --- drive to completion; time the switch storm ---
	tRun0 := time.now()
	rt.runAll()
	tRun := time.duration_seconds(time.since(tRun0))

	if done != n {
		fmt.eprintfln("only %d/%d coroutines finished", done, n)
		os.exit(1)
	}

	switches := f64(n) * f64(k + 1) // k yields + 1 final schedule each
	fmt.printfln("async scale: N=%d K=%d", n, k)
	fmt.printfln(
		"  spawn:   %d coros in %.1f ms  = %.2f M coros/sec",
		n,
		tSpawn * 1000,
		f64(n) / tSpawn / 1e6,
	)
	fmt.printfln(
		"  run:     %d switches in %.1f ms  = %.2f M switches/sec",
		int(switches),
		tRun * 1000,
		switches / tRun / 1e6,
	)
}
