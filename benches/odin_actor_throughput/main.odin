// benches/odin_actor_throughput/main.odin
//
// The Odin twin of benches/bench_actor_throughput.nim: one actor, N messages
// enqueued and drained. Exercises the mailbox ring and the actor wake path
// rather than raw context switching.
//
// Note the shapes differ where the runtimes legitimately differ: the Nim
// mailbox here is a `seq[int]` drained by setLen(0), while Odin uses the
// runtime's fixed-capacity ring (rt.Mailbox), which is what codegen actually
// emits for an actor. So this measures the real emitted path on each side.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
import rt "../../compiler/tuckrt"

MailCap :: 4096

mailbox: rt.Mailbox(int, MailCap)
sum: i64
handled: int

drain :: proc() {
	for {
		msg: int
		for rt.dequeue(&mailbox, &msg) {
			sum += i64(msg)
			handled += 1
		}
		rt.coroYield()
	}
}

main :: proc() {
	n := 1_000_000
	if len(os.args) >= 2 do n, _ = strconv.parse_int(os.args[1])

	rt.tuckAsyncInit()
	rt.tuckStartActor(drain)

	t0 := time.now()
	sent := 0
	for sent < n {
		// One send + one notify per message, matching what the Nim bench
		// does (`mailbox.add(i); tuckNotifySend()`) so the two measure the
		// same workload. The ring is finite and a full one drops (spec
		// §9.1), so drain when it fills — the seq-backed Nim mailbox grows
		// instead, which is the one shape difference left.
		if rt.hasRoom(&mailbox) {
			rt.enqueue(&mailbox, sent)
			sent += 1
			rt.tuckNotifySend()
		} else {
			rt.runNext()
		}
	}
	// drain whatever is still queued
	for handled < n {
		if !rt.runNext() do break
	}
	elapsed := time.duration_seconds(time.since(t0))

	if handled != n {
		fmt.eprintfln("only %d/%d messages handled", handled, n)
		os.exit(1)
	}
	want := i64(n) * i64(n - 1) / 2
	if sum != want {
		fmt.eprintfln("sum mismatch: got %d want %d", sum, want)
		os.exit(1)
	}

	fmt.printfln("actor throughput: N=%d", n)
	fmt.printfln(
		"  %d msgs in %.1f ms  = %.2f M msgs/sec",
		n,
		elapsed * 1000,
		f64(n) / elapsed / 1e6,
	)
}
