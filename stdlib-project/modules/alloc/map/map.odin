#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"

tuck_Entry :: struct($K: typeid, $V: typeid) {
	key: K,
	value: V,
}

tuck_Table :: struct($K: typeid, $V: typeid) {
	entries: [dynamic]tuck_Entry(K, V),
}

tuck_indexOf :: proc (t: tuck_Table($K, $V), key: K) -> int {
  for tuck_i in (0 ..= (len(t.entries) - 1)) {
      tuck_e := rt.tuckAt(t.entries, tuck_i)
      if (tuck_e.key == key) {
          return tuck_i
      }
  }
  return (0 - 1)
}

tuck_has :: proc (t: tuck_Table($K, $V), key: K) -> bool {
  return (tuck_indexOf(t, key) >= 0)
}

tuck_count :: proc (t: tuck_Table($K, $V)) -> int {
  return len(t.entries)
}

tuck_get :: proc (t: tuck_Table($K, $V), key: K) -> rt.TuckResult(V) {
  tuckfn_at := tuck_indexOf(t, key)
  if (tuckfn_at < 0) {
      return rt.tnone(V)
  }
  return rt.tok(rt.tuckAt(t.entries, tuckfn_at).value)
}

tuck_set :: proc (t: tuck_Table($K, $V), key: K, value: V) -> tuck_Table(K, V) {
  t := t
  t.entries = rt.tuckSeqCopy(t.entries)
  return tuck_set_moved(t, key, value)
}

tuck_set_moved :: proc (t: tuck_Table($K, $V), key: K, value: V) -> tuck_Table(K, V) {
  tuckfn_at := tuck_indexOf(t, key)
  tuck_es := t.entries
  tuck_fresh := tuck_Entry(K, V){key = key, value = value}
  if (tuckfn_at >= 0) {
      rt.tuckSetAt(tuck_es, tuckfn_at, tuck_fresh)
      return tuck_Table(K, V){entries = tuck_es}
  }
  append(&tuck_es, tuck_fresh)
  return tuck_Table(K, V){entries = tuck_es}
}

tuck_getOrSet :: proc (t: tuck_Table($K, $V), key: K, value: V) -> tuck_Table(K, V) {
  t := t
  t.entries = rt.tuckSeqCopy(t.entries)
  return tuck_getOrSet_moved(t, key, value)
}

tuck_getOrSet_moved :: proc (t: tuck_Table($K, $V), key: K, value: V) -> tuck_Table(K, V) {
  if tuck_has(t, key) {
      return t
  }
  return tuck_set(t, key, value)
}

tuck_remove :: proc (t: tuck_Table($K, $V), key: K) -> tuck_Table(K, V) {
  t := t
  t.entries = rt.tuckSeqCopy(t.entries)
  return tuck_remove_moved(t, key)
}

tuck_remove_moved :: proc (t: tuck_Table($K, $V), key: K) -> tuck_Table(K, V) {
  tuck_es: [dynamic]tuck_Entry(K, V) = [dynamic]tuck_Entry(K, V){}
  for tuck_i in (0 ..= (len(t.entries) - 1)) {
      tuck_e := rt.tuckAt(t.entries, tuck_i)
      if (tuck_e.key != key) {
          append(&tuck_es, tuck_e)
      }
  }
  return tuck_Table(K, V){entries = tuck_es}
}

tuck_clear :: proc (t: tuck_Table($K, $V)) -> tuck_Table(K, V) {
  t := t
  t.entries = rt.tuckSeqCopy(t.entries)
  return tuck_clear_moved(t)
}

tuck_clear_moved :: proc (t: tuck_Table($K, $V)) -> tuck_Table(K, V) {
  tuck_empty: [dynamic]tuck_Entry(K, V) = [dynamic]tuck_Entry(K, V){}
  return tuck_Table(K, V){entries = tuck_empty}
}

tuck_keys :: proc (t: tuck_Table($K, $V)) -> [dynamic]K {
  tuck_acc: [dynamic]K = [dynamic]K{}
  for tuck_i in (0 ..= (len(t.entries) - 1)) {
      append(&tuck_acc, rt.tuckAt(t.entries, tuck_i).key)
  }
  return tuck_acc
}

tuck_values :: proc (t: tuck_Table($K, $V)) -> [dynamic]V {
  tuck_acc: [dynamic]V = [dynamic]V{}
  for tuck_i in (0 ..= (len(t.entries) - 1)) {
      append(&tuck_acc, rt.tuckAt(t.entries, tuck_i).value)
  }
  return tuck_acc
}

tuck_pairs :: proc (t: tuck_Table($K, $V)) -> [dynamic]tuck_Entry(K, V) {
  return t.entries
}

tuck_main :: proc () -> int {
  tuck_rooms: tuck_Table(string, int) = tuck_Table(string, int){entries = [dynamic]tuck_Entry(string, int){}}
  tuck_rooms = tuck_set_moved(tuck_rooms, "lobby", 1)
  tuck_rooms = tuck_set_moved(tuck_rooms, "attic", 2)
  if (tuck_count(tuck_rooms) != 2) {
      return 1
  }
  tuck_lobby := tuck_get(tuck_rooms, "lobby")
  if !(tuck_lobby.status == .Ok) {
      return 2
  }
  if (tuck_lobby.value != 1) {
      return 3
  }
  tuck_missing := tuck_get(tuck_rooms, "cellar")
  if (tuck_missing.status == .Ok) {
      return 4
  }
  tuck_rooms = tuck_set_moved(tuck_rooms, "lobby", 9)
  if (tuck_count(tuck_rooms) != 2) {
      return 5
  }
  tuck_again := tuck_get(tuck_rooms, "lobby")
  if !(tuck_again.status == .Ok) {
      return 6
  }
  if (tuck_again.value != 9) {
      return 14
  }
  tuck_rooms = tuck_getOrSet_moved(tuck_rooms, "lobby", 99)
  tuck_kept := tuck_get(tuck_rooms, "lobby")
  if !(tuck_kept.status == .Ok) {
      return 7
  }
  if (tuck_kept.value != 9) {
      return 15
  }
  if !tuck_has(tuck_rooms, "attic") {
      return 8
  }
  tuck_rooms = tuck_remove_moved(tuck_rooms, "attic")
  if tuck_has(tuck_rooms, "attic") {
      return 9
  }
  if (tuck_count(tuck_rooms) != 1) {
      return 10
  }
  tuck_ks := rt.tuckSeqCopy(tuck_keys(tuck_rooms))
  if (len(tuck_ks) != 1) {
      return 11
  }
  tuck_vs := rt.tuckSeqCopy(tuck_values(tuck_rooms))
  if (len(tuck_vs) != 1) {
      return 12
  }
  tuck_rooms = tuck_clear_moved(tuck_rooms)
  if (tuck_count(tuck_rooms) != 0) {
      return 13
  }
  return 0
}

main :: proc() {
	mainRc := tuck_main()
	os.exit(mainRc)
}
