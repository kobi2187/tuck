// The registry's SEMANTICS, asserted against the Odin runtime. The twin of
// tests/rt_resources/nim_check.nim and of d_check.d: the identical list in
// all three, which is the point — three runtimes, one behaviour.
//
// tests/suites/resources_rt.nim stages compiler/tuckrt beside this file and
// runs `odin run` over the directory.
package main

import "core:fmt"
import "core:os"
import rt "./tuckrt"

closed: [dynamic]i64
flushed: [dynamic]i64
onClose :: proc(r: i64) { append(&closed, r) }
onFinish :: proc(r: i64) { append(&flushed, r) }

failures := 0

eq :: proc(a: []i64, b: []i64) -> bool {
	if len(a) != len(b) { return false }
	for x, i in a { if x != b[i] { return false } }
	return true
}

check :: proc(name: string, cond: bool) {
	if cond {
		fmt.println("  PASS ", name)
	} else {
		fmt.println("  FAIL ", name)
		failures += 1
	}
}

main :: proc() {
	files: rt.ResourceTable
	rt.initResourceTable(&files, "file", 8, .Strict, 0)
	rt.setResourceHooks(&files, onFinish, onClose)
	h1 := rt.acquireResource(&files, 100, "a.tuck:3")
	check("acquire succeeds", h1.status == .Ok)
	check("deref reaches the OS handle", rt.derefResource(&files, h1.value) == 100)
	check("an unfinished entry is open", rt.openResourceCount(&files) == 1)
	rt.finishResource(&files, h1.value)
	check("strict: on_finish ran at the mark", eq(flushed[:], []i64{100}))
	check("strict: the handle closed at the mark", eq(closed[:], []i64{100}))
	check("strict: nothing is left open", rt.openResourceCount(&files) == 0)

	clear(&closed); clear(&flushed)
	net: rt.ResourceTable
	rt.initResourceTable(&net, "net", 4, .Lazy, 0)
	rt.setResourceHooks(&net, onFinish, onClose)
	hs: [dynamic]rt.ResourceHandle
	for i in 0 ..< 4 { append(&hs, rt.acquireResource(&net, i64(i), "x").value) }
	check("a capped table fills to its cap", rt.openResourceCount(&net) == 4)
	check("...and then reports absence, not an error",
	      rt.acquireResource(&net, 99, "x").status == .Absent)
	rt.finishResource(&net, hs[0])
	check("lazy: on_finish ran at the mark", eq(flushed[:], []i64{0}))
	check("lazy: but nothing closed yet (1 of 4 is under the watermark)",
	      len(closed) == 0)
	rt.finishResource(&net, hs[1])
	rt.finishResource(&net, hs[2])
	check("lazy: the ~75% watermark (3 of 4) swept INLINE, inside the mark",
	      len(closed) == 3)

	clear(&closed); clear(&flushed)
	socks: rt.ResourceTable
	rt.initResourceTable(&socks, "sock", 0, .Exit, 0)
	rt.setResourceHooks(&socks, onFinish, onClose)
	a := rt.acquireResource(&socks, 1, "s1").value
	rt.acquireResource(&socks, 2, "s2")
	rt.acquireResource(&socks, 3, "s3")
	check("an uncapped table grows past any fixed size", len(socks.entries) == 3)
	rt.finishResource(&socks, a)
	check("exit: the mark closes nothing", len(closed) == 0)
	rt.closeAllResources(&socks)
	check("exit: close-all runs LIFO in REGISTRATION order", eq(closed[:], []i64{3, 2, 1}))
	check("...and flushes only what was never finished", eq(flushed[:], []i64{1, 3, 2}))

	t2: rt.ResourceTable
	rt.initResourceTable(&t2, "k", 2, .Exit, 0)
	x := rt.acquireResource(&t2, 7, "q").value
	rt.finishResource(&t2, x)
	check("the generation moves on AT THE MARK, so the handle dies there",
	      t2.entries[int(x.slot)].gen != x.gen)

	// What lets every backend emit the declaration as a static initializer
	// with no start-up code: the runtime sizes a capped table on first use.
	lit: rt.ResourceTable = {kind = "lit", cap = 2, policy = .Exit, sweepBatch = 0}
	check("a table built as a plain literal sizes itself on first acquire",
	      rt.acquireResource(&lit, 5, "l").status == .Ok)
	check("...and still honours its cap",
	      rt.acquireResource(&lit, 6, "l").status == .Ok &&
	      rt.acquireResource(&lit, 7, "l").status == .Absent)

	rep: rt.ResourceTable
	rt.initResourceTable(&rep, "file", 4, .Exit, 0)
	k1 := rt.acquireResource(&rep, 1, "main.tuck:4").value
	rt.acquireResource(&rep, 2, "main.tuck:9")
	rt.finishResource(&rep, k1)
	check("the report lists only what was never finished, with its site",
	      rt.openResourceCount(&rep) == 1)

	if failures > 0 { os.exit(1) }
}
