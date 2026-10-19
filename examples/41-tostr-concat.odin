#+feature dynamic-literals
package main

import rt "./tuckrt"
import tuckˑmodˑconsole "./mod_console"
import tuckˑmodˑstr "./mod_str"
import tuckˑmodˑsys "./mod_sys"

tuckˑtypeˑJar :: struct {
	count: int,
	label: string,
}

tuckˑfnˑmain :: proc () {
  tuckˑvˑn := 99
  tuckOwnTmp1 := tuckˑmodˑstr.toStr(tuckˑvˑn)
  defer rt.tuckDrop(tuckOwnTmp1)
  tuckˑvˑs := rt.tuckConcat(tuckOwnTmp1, " bottles")
  defer rt.tuckDrop(tuckˑvˑs)
  tuckˑmodˑconsole.printLine(tuckˑvˑs)
  tuckOwnTmp2 := tuckˑmodˑstr.toStr(tuckˑvˑn)
  defer rt.tuckDrop(tuckOwnTmp2)
  tuckˑvˑt := rt.tuckConcat(tuckOwnTmp2, " more")
  defer rt.tuckDrop(tuckˑvˑt)
  tuckˑmodˑconsole.printLine(tuckˑvˑt)
  tuckˑvˑj := tuckˑtypeˑJar{count = 7, label = rt.tuckStrOwned("jam")}
  defer rt.tuckDrop(tuckˑvˑj.label)
  tuckˑvˑc := tuckˑvˑj.count
  tuckOwnTmp3 := rt.tuckConcat(tuckˑvˑj.label, ": ")
  defer rt.tuckDrop(tuckOwnTmp3)
  tuckOwnTmp4 := tuckˑmodˑstr.toStr(tuckˑvˑc)
  defer rt.tuckDrop(tuckOwnTmp4)
  tuckˑvˑu := rt.tuckConcat(tuckOwnTmp3, tuckOwnTmp4)
  defer rt.tuckDrop(tuckˑvˑu)
  tuckˑmodˑconsole.printLine(tuckˑvˑu)
  if (tuckˑvˑs == "99 bottles") {
      if (tuckˑvˑu == "jam: 7") {
          tuckˑmodˑsys.exit(0)
      }
  }
  tuckˑmodˑsys.exit(1)
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuckˑfnˑmain()
	rt.tuckTrackCheck()
}
