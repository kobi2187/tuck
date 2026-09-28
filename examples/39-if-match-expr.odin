#+feature dynamic-literals
package main

import sys "./mod_sys"

tuckˑtypeˑColor :: enum { Red, Green, Blue }

tuckˑfnˑmain :: proc () {
  tuckˑvˑhot := true
  tuckˑvˑlimit := (tuckˑvˑhot ? 90 : 20)
  tuckˑvˑc := tuckˑtypeˑColor.Green
  tuckˑvˑcode := ((tuckˑvˑc == tuckˑtypeˑColor.Red) ? 1 : ((tuckˑvˑc == tuckˑtypeˑColor.Green) ? 2 : 3))
  tuckˑvˑname := ((tuckˑvˑc == tuckˑtypeˑColor.Red) ? 10 : ((tuckˑvˑc == tuckˑtypeˑColor.Green) ? 20 : 30))
  tuckˑvˑscaled := ((tuckˑvˑc == tuckˑtypeˑColor.Red) ? (tuckˑvˑhot ? 100 : 1) : ((tuckˑvˑc == tuckˑtypeˑColor.Green) ? (tuckˑvˑhot ? 200 : 2) : (tuckˑvˑhot ? 300 : 3)))
  if (tuckˑvˑlimit == 90) {
      if (tuckˑvˑcode == 2) {
          if (tuckˑvˑname == 20) {
              if (tuckˑvˑscaled == 200) {
                  sys.exit(0)
              }
          }
      }
  }
  sys.exit(1)
}

main :: proc() {
	tuckˑfnˑmain()
}
