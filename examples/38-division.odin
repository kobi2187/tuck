#+feature dynamic-literals
package main

import sys "./mod_sys"

tuck_main :: proc () {
  tuck_q := (7 / 2)
  tuck_r := (7.0 / 2.0)
  tuck_budget := 100
  tuck_budget = (tuck_budget / 8)
  if (tuck_q == 3) {
      if (tuck_budget == 12) {
          if (tuck_r > 3.4) {
              sys.exit(0)
          }
      }
  }
  sys.exit(1)
}

main :: proc() {
	tuck_main()
}
