#+feature dynamic-literals
package main

tuckˑtypeˑPriority :: enum { High, Low }

tuckˑdecisionˑroute :: proc (priority: tuckˑtypeˑPriority, encrypted: bool) -> int {
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
