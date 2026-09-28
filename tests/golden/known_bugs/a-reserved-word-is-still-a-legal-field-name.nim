{.experimental: "codeReordering".}

proc tuckˑfnˑmain*(): int

type tuckˑtypeˑJob* = object
  priority*: int

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑj = tuckˑtypeˑJob(priority: 3)
  return tuckˑvˑj.priority

