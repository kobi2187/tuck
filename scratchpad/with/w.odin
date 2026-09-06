package main

import "core:os"

tuck_Task :: struct {
	title: string,
	done: bool,
	score: int,
}

tuck_complete :: proc (self: tuck_Task) -> tuck_Task {
  return tuck_Task{title = self.title, done = true, score = self.score}
}

tuck_rescore :: proc (self: tuck_Task, n: int) -> tuck_Task {
  return tuck_Task{title = self.title, done = false, score = n}
}

tuck_main :: proc () -> int {
  tuck_t := tuck_Task{title = "write it", done = false, score = 1}
  tuck_d := tuck_complete(tuck_t)
  tuck_r := tuck_rescore(tuck_d, 7)
  if (tuck_d.done && ((tuck_r.score == 7) && (!tuck_r.done && (tuck_r.title == "write it")))) {
      return 0
  }
  return 1
}

main :: proc() {
	mainRc := tuck_main()
	os.exit(mainRc)
}
