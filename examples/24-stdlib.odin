#+feature dynamic-literals
package main

import rt "./tuckrt"
import fs "./mod_fs"
import console "./mod_console"

tuckG_0_copy :: proc(value: $G) -> G {
	return rt.tuckStrOwned(value)
}
tuckG_0_drop :: proc(value: $G) {
	delete(value)
}
tuckG_0_reset :: proc(value: ^$G) { tuckG_0_drop(value^); value^ = {} }


TRec_content :: struct ($T_content: typeid) {
	content: T_content,
}

tuckG_2_copy :: proc(value: $G) -> G {
	out := value
	out.content = tuckG_0_copy(value.content)
	return out
}
tuckG_2_drop :: proc(value: $G) {
	tuckG_0_drop(value.content)
}
tuckG_2_reset :: proc(value: ^$G) { tuckG_2_drop(value^); value^ = {} }


tuckG_1_copy :: proc(value: $G) -> G {
	out := value
	if value.status == .Ok {
		out.value = tuckG_2_copy(value.value)
	} else { out.value = {} }
	return out
}
tuckG_1_drop :: proc(value: $G) {
	if value.status == .Ok { tuckG_2_drop(value.value) }
}
tuckG_1_reset :: proc(value: ^$G) { tuckG_1_drop(value^); value^ = {} }


tuckˑfnˑmain :: proc () {
  tuckˑvˑw := fs.writeFile("/tmp/tuck-demo.txt", "hello from tuck")
  if (tuckˑvˑw.status == .Ok) {
      tuckˑvˑr := fs.readFile(tuckG_0_copy("/tmp/tuck-demo.txt"))
      defer tuckG_1_drop(tuckˑvˑr)
      if (tuckˑvˑr.status == .Ok) {
          console.printLine(tuckˑvˑr.value.content)
          return
      }
  }
  console.printLine("stdlib demo failed")
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuckˑfnˑmain()
	rt.tuckTrackCheck()
}
