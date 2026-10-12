#+feature dynamic-literals
package main

import rt "./tuckrt"
import sys "./mod_sys"
import str "./mod_str"
import console "./mod_console"

tuckˑtypeˑJar :: struct {
	count: int,
	label: string,
}

tuckˑfnˑmain :: proc () {
  tuckˑvˑn := 99
  tuckOwnTmp1 := str.toStr(tuckˑvˑn)
  defer rt.tuckDrop(tuckOwnTmp1)
  tuckˑvˑs := rt.tuckConcat(tuckOwnTmp1, " bottles")
  defer rt.tuckDrop(tuckˑvˑs)
  console.printLine(tuckˑvˑs)
  tuckOwnTmp2 := str.toStr(tuckˑvˑn)
  defer rt.tuckDrop(tuckOwnTmp2)
  tuckˑvˑt := rt.tuckConcat(tuckOwnTmp2, " more")
  defer rt.tuckDrop(tuckˑvˑt)
  console.printLine(tuckˑvˑt)
  tuckˑvˑj := tuckˑtypeˑJar{count = 7, label = rt.tuckStrOwned("jam")}
  defer rt.tuckDrop(tuckˑvˑj.label)
  tuckˑvˑc := tuckˑvˑj.count
  tuckOwnTmp3 := rt.tuckConcat(tuckˑvˑj.label, ": ")
  defer rt.tuckDrop(tuckOwnTmp3)
  tuckOwnTmp4 := str.toStr(tuckˑvˑc)
  defer rt.tuckDrop(tuckOwnTmp4)
  tuckˑvˑu := rt.tuckConcat(tuckOwnTmp3, tuckOwnTmp4)
  defer rt.tuckDrop(tuckˑvˑu)
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
