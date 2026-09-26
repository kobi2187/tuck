#+feature dynamic-literals
package main

tuck_type_Priority :: enum { High, Low }

tuck_fn_route :: proc (priority: tuck_type_Priority, encrypted: bool) -> int {
  switch (((int(priority) * 2) + (encrypted ? 1 : 0)))
  {
  case 0: return 2;
  case 1: return 1;
  case: return 3;
  }
  return {}
}

main :: proc() {
}
