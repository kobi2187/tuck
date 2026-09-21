#+feature dynamic-literals
package main

import rt "./tuckrt"
import sys "./mod_sys"
import str "./mod_str"
import console "./mod_console"

tuck_Jar :: struct {
	count: int,
	label: string,
}

tuck_main :: proc () {
  tuck_n := 99
  tuck_s := rt.tuckConcat(str.toStr(tuck_n), " bottles")
  console.printLine(tuck_s)
  tuck_t := rt.tuckConcat(str.toStr(tuck_n), " more")
  console.printLine(tuck_t)
  tuck_j := tuck_Jar{count = 7, label = "jam"}
  tuck_c := tuck_j.count
  tuck_u := rt.tuckConcat(rt.tuckConcat(tuck_j.label, ": "), str.toStr(tuck_c))
  console.printLine(tuck_u)
  if (tuck_s == "99 bottles") {
      if (tuck_u == "jam: 7") {
          sys.exit(0)
      }
  }
  sys.exit(1)
}

main :: proc() {
	tuck_main()
}
