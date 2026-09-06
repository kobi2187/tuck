{.experimental: "codeReordering".}
import ../../compiler/tuck_rt

type tuck_Task* = object
  title*: string
  done*: bool

proc tuck_main*(): int =
  var tuck_t = tuck_Task(title: "x", done: false)
  var tuck_b = (title: tuck_t.title, done: tuck_t.done, nosuchfield: 42)
  return 0

