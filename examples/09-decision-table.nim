{.experimental: "codeReordering".}
import "../compiler/tuck_rt"

proc tuckˑdecisionˑclassifyPacket*(urgency: tuckˑtypeˑPriority, size: tuckˑtypeˑSizeClass, encrypted: bool): tuckˑtypeˑAction

type tuckˑtypeˑPriority* = enum high, low

type tuckˑtypeˑSizeClass* = enum big, small

type tuckˑtypeˑAction* = enum QueueSecure, QueueFast, QueueImmediate, QueueDefer

proc tuckˑdecisionˑclassifyPacket*(urgency: tuckˑtypeˑPriority, size: tuckˑtypeˑSizeClass, encrypted: bool): tuckˑtypeˑAction =
  (case (((ord(urgency) * 4) + (ord(size) * 2)) + ord(encrypted))
  of 0:
    if true:
      return QueueFast
  of 1:
    if true:
      return QueueSecure
  of 2, 3:
    if true:
      return QueueImmediate
  else:
    if true:
      return QueueDefer)

