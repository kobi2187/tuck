#+feature dynamic-literals
package main

import tuckˑmodˑsys "./mod_sys"

tuckˑfnˑmain :: proc () {
  tuckˑvˑq := (7 / 2)
  tuckˑvˑr := (7.0 / 2.0)
  tuckˑvˑbudget := 100
  tuckˑvˑbudget = (tuckˑvˑbudget / 8)
  if (tuckˑvˑq == 3) {
      if (tuckˑvˑbudget == 12) {
          if (tuckˑvˑr > 3.4) {
              tuckˑmodˑsys.exit(0)
          }
      }
  }
  tuckˑmodˑsys.exit(1)
}

main :: proc() {
	tuckˑfnˑmain()
}
