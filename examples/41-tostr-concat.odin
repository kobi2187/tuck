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
  n := 99
  s := rt.tuckConcat(str.toStr(n), " bottles")
  console.printLine(s)
  t := rt.tuckConcat(str.toStr(n), " more")
  console.printLine(t)
  j := tuck_Jar{count = 7, label = "jam"}
  c := j.count
  u := rt.tuckConcat(rt.tuckConcat(j.label, ": "), str.toStr(c))
  console.printLine(u)
  if (s == "99 bottles") {
      if (u == "jam: 7") {
          sys.exit(0)
      }
  }
  sys.exit(1)
}

main :: proc() {
	tuck_main()
}
