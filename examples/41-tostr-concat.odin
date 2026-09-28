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
  tuckStrTmp1 := str.toStr(tuckˑvˑn)
  defer delete(tuckStrTmp1)
  tuckˑvˑs := rt.tuckConcat(tuckStrTmp1, " bottles")
  defer delete(tuckˑvˑs)
  console.printLine(tuckˑvˑs)
  tuckStrTmp2 := str.toStr(tuckˑvˑn)
  defer delete(tuckStrTmp2)
  tuckˑvˑt := rt.tuckConcat(tuckStrTmp2, " more")
  defer delete(tuckˑvˑt)
  console.printLine(tuckˑvˑt)
  tuckˑvˑj := tuckˑtypeˑJar{count = 7, label = "jam"}
  tuckˑvˑc := tuckˑvˑj.count
  tuckStrTmp3 := rt.tuckConcat(tuckˑvˑj.label, ": ")
  defer delete(tuckStrTmp3)
  tuckStrTmp4 := str.toStr(tuckˑvˑc)
  defer delete(tuckStrTmp4)
  tuckˑvˑu := rt.tuckConcat(tuckStrTmp3, tuckStrTmp4)
  defer delete(tuckˑvˑu)
  console.printLine(tuckˑvˑu)
  if (tuckˑvˑs == "99 bottles") {
      if (tuckˑvˑu == "jam: 7") {
          sys.exit(0)
      }
  }
  sys.exit(1)
}

main :: proc() {
	tuckˑfnˑmain()
}
