#+feature dynamic-literals
package main

tuckˑtypeˑPriority :: enum { high, low }

tuckˑtypeˑSizeClass :: enum { big, small }

tuckˑtypeˑAction :: enum { QueueSecure, QueueFast, QueueImmediate, QueueDefer }

tuckˑdecisionˑclassifyPacket :: proc (priority: tuckˑtypeˑPriority, size: tuckˑtypeˑSizeClass, encrypted: bool) -> tuckˑtypeˑAction {
  switch ((((int(priority) * 4) + (int(size) * 2)) + (encrypted ? 1 : 0)))
  {
  case 0: return tuckˑtypeˑAction.QueueFast;
  case 1: return tuckˑtypeˑAction.QueueSecure;
  case 2, 3: return tuckˑtypeˑAction.QueueImmediate;
  case: return tuckˑtypeˑAction.QueueDefer;
  }
  return {}
}

main :: proc() {
}
