{.experimental: "codeReordering".}
import ../../compiler/tuck_rt

type tuck_Task* = object
  title*: string
  done*: bool
  score*: int

proc tuck_complete*(self: tuck_Task): tuck_Task =
  return tuck_Task(title: self.title, done: true, score: self.score)

proc tuck_rescore*(self: tuck_Task, n: int): tuck_Task =
  return tuck_Task(title: self.title, done: false, score: n)

proc tuck_main*(): int =
  var tuck_t = tuck_Task(title: "write it", done: false, score: 1)
  var tuck_d = tuck_complete(tuck_t)
  var tuck_r = tuck_rescore(tuck_d, 7)
  if (tuck_d.done and ((tuck_r.score == 7) and (not tuck_r.done and (tuck_r.title == "write it")))):
    if true:
      return 0
  return 1


when isMainModule:
  quit(tuck_main())
