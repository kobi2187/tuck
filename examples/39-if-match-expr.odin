package main

import sys "./mod_sys"

tuck_Color :: enum { Red, Green, Blue }

tuck_main :: proc () {
  tuck_hot := true
  tuck_limit := (tuck_hot ? 90 : 20)
  tuck_c := tuck_Color.Green
  tuck_code := ((tuck_c == tuck_Color.Red) ? 1 : ((tuck_c == tuck_Color.Green) ? 2 : 3))
  tuck_name := ((tuck_c == tuck_Color.Red) ? 10 : ((tuck_c == tuck_Color.Green) ? 20 : 30))
  tuck_scaled := ((tuck_c == tuck_Color.Red) ? (tuck_hot ? 100 : 1) : ((tuck_c == tuck_Color.Green) ? (tuck_hot ? 200 : 2) : (tuck_hot ? 300 : 3)))
  if (tuck_limit == 90) {
      if (tuck_code == 2) {
          if (tuck_name == 20) {
              if (tuck_scaled == 200) {
                  sys.exit(0)
              }
          }
      }
  }
  sys.exit(1)
}

main :: proc() {
	tuck_main()
}
