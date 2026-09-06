{.experimental: "codeReordering".}
import ../../compiler/tuck_rt

type tuck_Task* = object
  title*: string
  done*: bool

proc tuck_main*(): int =
  var tuck_t = tuck_Task(title: "x", done: false)
  var tuck_b = tuck_Task(title: tuck_t.title, done: true)
  if (tuck_b.done and (tuck_b.title == "x")):
    if true:
      return 0
  return 1


when isMainModule:
  quit(tuck_main())
