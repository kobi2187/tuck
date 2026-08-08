package main

import sys "./mod_sys"

tuck_double :: proc (value: int) -> int {
  return (value * 2)
}

tuck_addTen :: proc (value: int) -> int {
  return (value + 10)
}

tuck_main :: proc () {
  a := tuck_double(5)
  b := tuck_addTen(tuck_double(10))
  total := (a + b)
  sys.exit(total)
}

main :: proc() {
	tuck_main()
}
