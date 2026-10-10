#+feature dynamic-literals
package main

import rt "./tuckrt"
import sys "./mod_sys"
import str "./mod_str"
import console "./mod_console"

tuckG_0_copy :: proc(value: $G) -> G {
	return rt.tuckStrOwned(value)
}
tuckG_0_drop :: proc(value: $G) {
	delete(value)
}
tuckG_0_reset :: proc(value: ^$G) { tuckG_0_drop(value^); value^ = {} }


tuckˑtypeˑJar :: struct {
	count: int,
	label: string,
}

tuckˑfnˑmain :: proc () {
  tuckˑvˑn := 99
  tuckOwnTmp1 := str.toStr(tuckˑvˑn)
  defer tuckG_0_drop(tuckOwnTmp1)
  tuckˑvˑs := rt.tuckConcat(tuckOwnTmp1, " bottles")
  defer tuckG_0_drop(tuckˑvˑs)
  console.printLine(tuckˑvˑs)
  tuckOwnTmp2 := str.toStr(tuckˑvˑn)
  defer tuckG_0_drop(tuckOwnTmp2)
  tuckˑvˑt := rt.tuckConcat(tuckOwnTmp2, " more")
  defer tuckG_0_drop(tuckˑvˑt)
  console.printLine(tuckˑvˑt)
  tuckˑvˑj := tuckˑtypeˑJar{count = 7, label = tuckG_0_copy("jam")}
  defer tuckG_0_drop(tuckˑvˑj.label)
  tuckˑvˑc := tuckˑvˑj.count
  tuckOwnTmp3 := rt.tuckConcat(tuckˑvˑj.label, ": ")
  defer tuckG_0_drop(tuckOwnTmp3)
  tuckOwnTmp4 := str.toStr(tuckˑvˑc)
  defer tuckG_0_drop(tuckOwnTmp4)
  tuckˑvˑu := rt.tuckConcat(tuckOwnTmp3, tuckOwnTmp4)
  defer tuckG_0_drop(tuckˑvˑu)
  console.printLine(tuckˑvˑu)
  if (tuckˑvˑs == "99 bottles") {
      if (tuckˑvˑu == "jam: 7") {
          sys.exit(0)
      }
  }
  sys.exit(1)
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuckˑfnˑmain()
	rt.tuckTrackCheck()
}
