#+feature dynamic-literals
package main

tuck_type_Priority :: enum { high, low }

tuck_type_SizeClass :: enum { big, small }

tuck_type_Action :: enum { QueueSecure, QueueFast, QueueImmediate, QueueDefer }

tuck_fn_classifyPacket :: proc (priority: tuck_type_Priority, size: tuck_type_SizeClass, encrypted: bool) -> tuck_type_Action {
  switch ((((int(priority) * 4) + (int(size) * 2)) + (encrypted ? 1 : 0)))
  {
  case 0: return tuck_type_Action.QueueFast;
  case 1: return tuck_type_Action.QueueSecure;
  case 2, 3: return tuck_type_Action.QueueImmediate;
  case: return tuck_type_Action.QueueDefer;
  }
  return {}
}

main :: proc() {
}
