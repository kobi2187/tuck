package main

import sys "./mod_sys"

tuck_main :: proc () {
  q := (7 / 2)
  r := (7.0 / 2.0)
  budget := 100
  budget = (budget / 8)
  if (q == 3) {
      if (budget == 12) {
          if (r > 3.4) {
              sys.exit(0)
          }
      }
  }
  sys.exit(1)
}

main :: proc() {
	tuck_main()
}
