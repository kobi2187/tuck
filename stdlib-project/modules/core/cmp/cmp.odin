#+feature dynamic-literals
package main

import "core:os"

tuck_Order :: enum { Before, Same, After }

// interface Sortable: no satisfying types

tuck_flipped :: proc (o: tuck_Order) -> tuck_Order {
  switch (o)
  {
  case tuck_Order.Before: return tuck_Order.After;
  case tuck_Order.Same: return tuck_Order.Same;
  case tuck_Order.After: return tuck_Order.Before;
  }
  return {}
}

tuck_breakTiesWith :: proc (o: tuck_Order, next: tuck_Order) -> tuck_Order {
  switch (o)
  {
  case tuck_Order.Same: return next;
  case tuck_Order.Before: return tuck_Order.Before;
  case tuck_Order.After: return tuck_Order.After;
  }
  return {}
}

tuck_isBefore :: proc (o: tuck_Order) -> bool {
  switch (o)
  {
  case tuck_Order.Before: return true;
  case tuck_Order.Same: return false;
  case tuck_Order.After: return false;
  }
  return {}
}

tuck_smaller :: proc (a: $T, b: T) -> T {
  if (a < b) {
      return a
  }
  return b
}

tuck_larger :: proc (a: $T, b: T) -> T {
  if (a < b) {
      return b
  }
  return a
}

tuck_clamped :: proc (x: $T, low: T, high: T) -> T {
  if (x < low) {
      return low
  }
  if (high < x) {
      return high
  }
  return x
}

tuck_main :: proc () -> int {
  tuck_f := tuck_flipped(tuck_Order.Before)
  tuck_t := tuck_breakTiesWith(tuck_Order.Same, tuck_Order.After)
  if tuck_isBefore(tuck_f) {
      return 1
  }
  if tuck_isBefore(tuck_t) {
      return 2
  }
  tuck_s := tuck_smaller(3, 9)
  tuck_l := tuck_larger(3, 9)
  tuck_c := tuck_clamped(42, 0, 10)
  return (((tuck_s + tuck_l) - tuck_c) - 2)
}

main :: proc() {
	mainRc := tuck_main()
	os.exit(mainRc)
}
