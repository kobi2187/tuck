package main

import sys "./mod_sys"

tuck_Color :: enum { Red, Green, Blue }

tuck_main :: proc () {
  hot := true
  limit := (hot ? 90 : 20)
  c := tuck_Color.Green
  code := ((c == tuck_Color.Red) ? 1 : ((c == tuck_Color.Green) ? 2 : 3))
  name := ((c == tuck_Color.Red) ? 10 : ((c == tuck_Color.Green) ? 20 : 30))
  scaled := ((c == tuck_Color.Red) ? (hot ? 100 : 1) : ((c == tuck_Color.Green) ? (hot ? 200 : 2) : (hot ? 300 : 3)))
  if (limit == 90) {
      if (code == 2) {
          if (name == 20) {
              if (scaled == 200) {
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
