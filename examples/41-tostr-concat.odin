#+feature dynamic-literals
package main

import rt "./tuckrt"
import sys "./mod_sys"
import str "./mod_str"
import console "./mod_console"

tuck_type_Jar :: struct {
	count: int,
	label: string,
}

tuck_fn_main :: proc () {
  tuck_n := 99
  tuckStrTmp1 := str.toStr(tuck_n)
  defer delete(tuckStrTmp1)
  tuck_s := rt.tuckConcat(tuckStrTmp1, " bottles")
  defer delete(tuck_s)
  console.printLine(tuck_s)
  tuckStrTmp2 := str.toStr(tuck_n)
  defer delete(tuckStrTmp2)
  tuck_t := rt.tuckConcat(tuckStrTmp2, " more")
  defer delete(tuck_t)
  console.printLine(tuck_t)
  tuck_j := tuck_type_Jar{count = 7, label = "jam"}
  tuck_c := tuck_j.count
  tuckStrTmp3 := rt.tuckConcat(tuck_j.label, ": ")
  defer delete(tuckStrTmp3)
  tuckStrTmp4 := str.toStr(tuck_c)
  defer delete(tuckStrTmp4)
  tuck_u := rt.tuckConcat(tuckStrTmp3, tuckStrTmp4)
  defer delete(tuck_u)
  console.printLine(tuck_u)
  if (tuck_s == "99 bottles") {
      if (tuck_u == "jam: 7") {
          sys.exit(0)
      }
  }
  sys.exit(1)
}

main :: proc() {
	tuck_fn_main()
}
