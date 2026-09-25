{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuck_fn_classifyPacket*(priority: tuck_type_Priority, size: tuck_type_SizeClass, encrypted: bool): tuck_type_Action

type tuck_type_Priority* = enum high, low

type tuck_type_SizeClass* = enum big, small

type tuck_type_Action* = enum QueueSecure, QueueFast, QueueImmediate, QueueDefer

proc tuck_fn_classifyPacket*(priority: tuck_type_Priority, size: tuck_type_SizeClass, encrypted: bool): tuck_type_Action =
  (case (((ord(priority) * 4) + (ord(size) * 2)) + ord(encrypted))
  of 0:
    return QueueFast
  of 1:
    return QueueSecure
  of 2, 3:
    return QueueImmediate
  else:
    return QueueDefer)

