{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuckˑdecisionˑclassifyPacket*(priority: tuckˑtypeˑPriority, size: tuckˑtypeˑSizeClass, encrypted: bool): tuckˑtypeˑAction

type tuckˑtypeˑPriority* = enum high, low

type tuckˑtypeˑSizeClass* = enum big, small

type tuckˑtypeˑAction* = enum QueueSecure, QueueFast, QueueImmediate, QueueDefer

proc tuckˑdecisionˑclassifyPacket*(priority: tuckˑtypeˑPriority, size: tuckˑtypeˑSizeClass, encrypted: bool): tuckˑtypeˑAction =
  (case (((ord(priority) * 4) + (ord(size) * 2)) + ord(encrypted))
  of 0:
    return QueueFast
  of 1:
    return QueueSecure
  of 2, 3:
    return QueueImmediate
  else:
    return QueueDefer)

