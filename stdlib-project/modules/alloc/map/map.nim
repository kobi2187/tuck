{.experimental: "codeReordering".}
import ../../../../compiler/tuck_rt
import seq as tuck_mod_seq

proc tuck_indexOf*[K, V](t: tuck_Table[K, V], key: K): int
proc tuck_has*[K, V](t: sink tuck_Table[K, V], key: K): bool
proc tuck_count*[K, V](t: sink tuck_Table[K, V]): int
proc tuck_get*[K, V](t: sink tuck_Table[K, V], key: K): TuckResult[V]
proc tuck_set*[K, V](t: sink tuck_Table[K, V], key: K, value: V): tuck_Table[K, V]
proc tuck_getOrSet*[K, V](t: sink tuck_Table[K, V], key: K, value: V): tuck_Table[K, V]
proc tuck_remove*[K, V](t: tuck_Table[K, V], key: K): tuck_Table[K, V]
proc tuck_clear*[K, V](t: tuck_Table[K, V]): tuck_Table[K, V]
proc tuck_keys*[K, V](t: tuck_Table[K, V]): seq[K]
proc tuck_values*[K, V](t: tuck_Table[K, V]): seq[V]
proc tuck_pairs*[K, V](t: sink tuck_Table[K, V]): seq[tuck_Entry[K, V]]
proc tuck_main*(): int

type tuck_Entry*[K, V] = object
  key*: K
  value*: V

type tuck_Table*[K, V] = object
  entries*: seq[tuck_Entry[K, V]]

proc tuck_indexOf*[K, V](t: tuck_Table[K, V], key: K): int =
  for tuck_i in (0 .. (t.entries.len - 1)):
    if true:
      var tuck_e = tuck_rt.tuckAt(t.entries, tuck_i)
      if (tuck_e.key == key):
        if true:
          return tuck_i
  return (0 - 1)

proc tuck_has*[K, V](t: sink tuck_Table[K, V], key: K): bool =
  return (tuck_indexOf(t, key) >= 0)

proc tuck_count*[K, V](t: sink tuck_Table[K, V]): int =
  return t.entries.len

proc tuck_get*[K, V](t: sink tuck_Table[K, V], key: K): TuckResult[V] =
  var tuckfn_at = tuck_indexOf(t, key)
  if (tuckfn_at < 0):
    if true:
      return tnone[V]()
  return tok(tuck_rt.tuckAt(t.entries, tuckfn_at).value)

proc tuck_set*[K, V](t: sink tuck_Table[K, V], key: K, value: V): tuck_Table[K, V] =
  var tuckfn_at = tuck_indexOf(t, key)
  var tuck_es = t.entries
  var tuck_fresh = tuck_Entry[K, V](key: key, value: value)
  if (tuckfn_at >= 0):
    if true:
      tuck_rt.tuckSetAt(tuck_es, tuckfn_at, tuck_fresh)
      return tuck_Table[K, V](entries: tuck_es)
  tuck_es.add(tuck_fresh)
  return tuck_Table[K, V](entries: tuck_es)

proc tuck_getOrSet*[K, V](t: sink tuck_Table[K, V], key: K, value: V): tuck_Table[K, V] =
  if tuck_has(t, key):
    if true:
      return t
  return tuck_set(t, key, value)

proc tuck_remove*[K, V](t: tuck_Table[K, V], key: K): tuck_Table[K, V] =
  var tuck_es: seq[tuck_Entry[K, V]] = @[]
  for tuck_i in (0 .. (t.entries.len - 1)):
    if true:
      var tuck_e = tuck_rt.tuckAt(t.entries, tuck_i)
      if (tuck_e.key != key):
        if true:
          tuck_es.add(tuck_e)
  return tuck_Table[K, V](entries: tuck_es)

proc tuck_clear*[K, V](t: tuck_Table[K, V]): tuck_Table[K, V] =
  var tuck_empty: seq[tuck_Entry[K, V]] = @[]
  return tuck_Table[K, V](entries: tuck_empty)

proc tuck_keys*[K, V](t: tuck_Table[K, V]): seq[K] =
  var tuck_acc: seq[K] = @[]
  for tuck_i in (0 .. (t.entries.len - 1)):
    if true:
      tuck_acc.add(tuck_rt.tuckAt(t.entries, tuck_i).key)
  return tuck_acc

proc tuck_values*[K, V](t: tuck_Table[K, V]): seq[V] =
  var tuck_acc: seq[V] = @[]
  for tuck_i in (0 .. (t.entries.len - 1)):
    if true:
      tuck_acc.add(tuck_rt.tuckAt(t.entries, tuck_i).value)
  return tuck_acc

proc tuck_pairs*[K, V](t: sink tuck_Table[K, V]): seq[tuck_Entry[K, V]] =
  return t.entries

proc tuck_main*(): int =
  var tuck_rooms: tuck_Table[string, int] = tuck_Table[string, int](entries: @[])
  tuck_rooms = tuck_set(tuck_rooms, "lobby", 1)
  tuck_rooms = tuck_set(tuck_rooms, "attic", 2)
  if (tuck_count(tuck_rooms) != 2):
    if true:
      return 1
  var tuck_lobby = tuck_get(tuck_rooms, "lobby")
  if not tuck_lobby.ok:
    if true:
      return 2
  if (tuck_lobby.value != 1):
    if true:
      return 3
  var tuck_missing = tuck_get(tuck_rooms, "cellar")
  if tuck_missing.ok:
    if true:
      return 4
  tuck_rooms = tuck_set(tuck_rooms, "lobby", 9)
  if (tuck_count(tuck_rooms) != 2):
    if true:
      return 5
  var tuck_again = tuck_get(tuck_rooms, "lobby")
  if not tuck_again.ok:
    if true:
      return 6
  if (tuck_again.value != 9):
    if true:
      return 14
  tuck_rooms = tuck_getOrSet(tuck_rooms, "lobby", 99)
  var tuck_kept = tuck_get(tuck_rooms, "lobby")
  if not tuck_kept.ok:
    if true:
      return 7
  if (tuck_kept.value != 9):
    if true:
      return 15
  if not tuck_has(tuck_rooms, "attic"):
    if true:
      return 8
  tuck_rooms = tuck_remove(tuck_rooms, "attic")
  if tuck_has(tuck_rooms, "attic"):
    if true:
      return 9
  if (tuck_count(tuck_rooms) != 1):
    if true:
      return 10
  var tuck_ks = tuck_keys(tuck_rooms)
  if (len(tuck_ks) != 1):
    if true:
      return 11
  var tuck_vs = tuck_values(tuck_rooms)
  if (len(tuck_vs) != 1):
    if true:
      return 12
  tuck_rooms = tuck_clear(tuck_rooms)
  if (tuck_count(tuck_rooms) != 0):
    if true:
      return 13
  return 0


when isMainModule:
  quit(tuck_main())
