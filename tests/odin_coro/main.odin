// tests/odin_coro/main.odin
// Self-check for compiler/tuckrt/tuck_coro.odin — the Odin coroutine engine.
// Run: odin run tests/odin_coro -out:/tmp/tuck_odin_coro
//
// Covers the three layers that can silently do nothing: coroutines really
// switch stacks, the scheduler really round-robins, and the reactor really
// sleeps (a timer that returns instantly would still "pass" a liveness-only
// test, so the sleep case asserts elapsed time).
package main

import "core:fmt"
import "core:os"
import "core:time"
import rt "../../compiler/tuckrt"

log: [dynamic]string

bodyA :: proc() {
	append(&log, "a1")
	rt.coroYield()
	append(&log, "a2")
	rt.coroYield()
	append(&log, "a3")
}

bodyB :: proc() {
	append(&log, "b1")
	rt.coroYield()
	append(&log, "b2")
}

slept: bool
sleeper :: proc() {
	rt.tuckSleep(120)
	slept = true
}

order: [dynamic]string
fast :: proc() {rt.tuckSleep(30);append(&order, "fast")}
slow :: proc() {rt.tuckSleep(150);append(&order, "slow")}

main :: proc() {
	// --- coroutines switch stacks and run to completion ---
	c := rt.newCoroutine(bodyA)
	for !rt.isFinished(c) {
		rt.resume(c)
	}
	assert(len(log) == 3 && log[0] == "a1" && log[2] == "a3",
	       "coroutine did not run to completion")

	// --- scheduler round-robins between two coroutines ---
	clear(&log)
	rt.schedule(rt.newCoroutine(bodyA))
	rt.schedule(rt.newCoroutine(bodyB))
	rt.runAll()
	// a1,b1 then a2,b2 then a3 — interleaved, not sequential.
	assert(len(log) == 5, "expected 5 log entries, got")
	assert(log[0] == "a1" && log[1] == "b1", "not round-robin")
	assert(log[2] == "a2" && log[3] == "b2", "not round-robin on 2nd pass")
	fmt.println("interleave:", log)

	// --- reactor timer actually waits ---
	rt.tuckAsyncInit()
	rt.tuckSpawn(sleeper)
	t0 := time.now()
	rt.tuckRun()
	elapsed := time.duration_milliseconds(time.since(t0))
	assert(slept, "timer coroutine never resumed")
	assert(elapsed >= 100, "tuckSleep returned too early")
	fmt.printf("tuckSleep(120) elapsed: %.0f ms\n", elapsed)

	// --- two timers complete in DURATION order, not spawn order ---
	rt.tuckSpawn(slow)
	rt.tuckSpawn(fast)
	rt.tuckRun()
	assert(len(order) == 2, "both timers should fire")
	assert(order[0] == "fast", "shorter timer must resume first")
	fmt.println("timer order:", order)

	fmt.println("OK - tuck_coro.odin: coroutines, scheduler, reactor verified")
	os.exit(0)
}
