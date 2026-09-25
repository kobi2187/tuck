{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuck_classifyPacket*(priority: tuck_Priority, size: tuck_SizeClass, encrypted: bool): tuck_Action

type tuck_Priority* = enum high, low

type tuck_SizeClass* = enum big, small

type tuck_Action* = enum QueueSecure, QueueFast, QueueImmediate, QueueDefer

proc tuck_classifyPacket*(priority: tuck_Priority, size: tuck_SizeClass, encrypted: bool): tuck_Action =
  (case (((ord(priority) * 4) + (ord(size) * 2)) + ord(encrypted))
  of 0:
    return QueueFast
  of 1:
    return QueueSecure
  of 2, 3:
    return QueueImmediate
  else:
    return QueueDefer)

