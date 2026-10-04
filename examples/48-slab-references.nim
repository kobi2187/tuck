{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuckˑfnˑemptyList*(): SlabRef
proc tuckˑfnˑafter*(n: SlabRef): SlabRef
proc tuckˑfnˑbefore*(n: SlabRef): SlabRef
proc tuckˑfnˑpushBack*(list: SlabRef, data: int): SlabRef
proc tuckˑfnˑremove*(n: SlabRef): void
proc tuckˑfnˑsumForward*(list: SlabRef): int
proc tuckˑfnˑsumBackward*(list: SlabRef): int
proc tuckˑfnˑaddFile*(dir: SlabRef, bytes: int): void
proc tuckˑfnˑdepth*(dir: SlabRef): int
proc tuckˑfnˑlapFrom*(at: SlabRef, start: SlabRef): int
proc tuckˑfnˑlapMinutes*(start: SlabRef): int
proc tuckˑfnˑmain*(): int

type tuckˑtypeˑNode* = object
  data*: int
  prev*: TuckResult[SlabRef]
  next*: TuckResult[SlabRef]

type tuckˑtypeˑDir* = object
  bytes*: int
  parent*: TuckResult[SlabRef]

type tuckˑtypeˑStop* = object
  minutes*: int
  next*: TuckResult[SlabRef]

var tuckˑslabˑNodes* = SlabChunked[tuckˑtypeˑNode](name: "Nodes")
proc tuckˑfnˑemptyList*(): SlabRef =
  var tuckˑvˑs = tuckSlabNew(tuckˑslabˑNodes, tuckˑtypeˑNode(data: 0, prev: TuckResult[SlabRef](status: tsAbsent), next: TuckResult[SlabRef](status: tsAbsent)))
  tuckSlabCell(tuckˑslabˑNodes, tuckˑvˑs).value.prev = TuckResult[SlabRef](status: tsOk, value: tuckˑvˑs)
  tuckSlabCell(tuckˑslabˑNodes, tuckˑvˑs).value.next = TuckResult[SlabRef](status: tsOk, value: tuckˑvˑs)
  return tuckˑvˑs

proc tuckˑfnˑafter*(n: SlabRef): SlabRef =
  var tuckˑvˑx = tuckSlabCell(tuckˑslabˑNodes, n).value.next
  if tuckˑvˑx.ok:
    if true:
      return tuckˑvˑx.value
  return n

proc tuckˑfnˑbefore*(n: SlabRef): SlabRef =
  var tuckˑvˑx = tuckSlabCell(tuckˑslabˑNodes, n).value.prev
  if tuckˑvˑx.ok:
    if true:
      return tuckˑvˑx.value
  return n

proc tuckˑfnˑpushBack*(list: SlabRef, data: int): SlabRef =
  var tuckˑvˑlast = tuckˑfnˑbefore(list)
  var tuckˑvˑn = tuckSlabNew(tuckˑslabˑNodes, tuckˑtypeˑNode(data: data, prev: TuckResult[SlabRef](status: tsOk, value: tuckˑvˑlast), next: TuckResult[SlabRef](status: tsOk, value: list)))
  tuckSlabCell(tuckˑslabˑNodes, tuckˑvˑlast).value.next = TuckResult[SlabRef](status: tsOk, value: tuckˑvˑn)
  tuckSlabCell(tuckˑslabˑNodes, list).value.prev = TuckResult[SlabRef](status: tsOk, value: tuckˑvˑn)
  return tuckˑvˑn

proc tuckˑfnˑremove*(n: SlabRef): void =
  var tuckˑvˑp = tuckˑfnˑbefore(n)
  var tuckˑvˑq = tuckˑfnˑafter(n)
  tuckSlabCell(tuckˑslabˑNodes, tuckˑvˑp).value.next = TuckResult[SlabRef](status: tsOk, value: tuckˑvˑq)
  tuckSlabCell(tuckˑslabˑNodes, tuckˑvˑq).value.prev = TuckResult[SlabRef](status: tsOk, value: tuckˑvˑp)
  tuckSlabFree(tuckˑslabˑNodes, n)

proc tuckˑfnˑsumForward*(list: SlabRef): int =
  var tuckˑvˑtotal = 0
  var tuckˑvˑcur = tuckˑfnˑafter(list)
  while (tuckˑvˑcur != list):
    if true:
      tuckˑvˑtotal = (tuckˑvˑtotal + tuckSlabCell(tuckˑslabˑNodes, tuckˑvˑcur).value.data)
      tuckˑvˑcur = tuckˑfnˑafter(tuckˑvˑcur)
  return tuckˑvˑtotal

proc tuckˑfnˑsumBackward*(list: SlabRef): int =
  var tuckˑvˑtotal = 0
  var tuckˑvˑcur = tuckˑfnˑbefore(list)
  while (tuckˑvˑcur != list):
    if true:
      tuckˑvˑtotal = (tuckˑvˑtotal + tuckSlabCell(tuckˑslabˑNodes, tuckˑvˑcur).value.data)
      tuckˑvˑcur = tuckˑfnˑbefore(tuckˑvˑcur)
  return tuckˑvˑtotal

var tuckˑslabˑDirs* = SlabChunked[tuckˑtypeˑDir](name: "Dirs")
proc tuckˑfnˑaddFile*(dir: SlabRef, bytes: int): void =
  tuckSlabCell(tuckˑslabˑDirs, dir).value.bytes = (tuckSlabCell(tuckˑslabˑDirs, dir).value.bytes + bytes)
  var tuckˑvˑup = tuckSlabCell(tuckˑslabˑDirs, dir).value.parent
  if tuckˑvˑup.ok:
    if true:
      tuckˑfnˑaddFile(tuckˑvˑup.value, bytes)

proc tuckˑfnˑdepth*(dir: SlabRef): int =
  var tuckˑvˑup = tuckSlabCell(tuckˑslabˑDirs, dir).value.parent
  if not tuckˑvˑup.ok:
    if true:
      return 0
  return (1 + tuckˑfnˑdepth(tuckˑvˑup.value))

var tuckˑslabˑStops* = SlabChunked[tuckˑtypeˑStop](name: "Stops")
proc tuckˑfnˑlapFrom*(at: SlabRef, start: SlabRef): int =
  if (at == start):
    if true:
      return 0
  var tuckˑvˑnext = tuckSlabCell(tuckˑslabˑStops, at).value.next
  if not tuckˑvˑnext.ok:
    if true:
      return tuckSlabCell(tuckˑslabˑStops, at).value.minutes
  return (tuckSlabCell(tuckˑslabˑStops, at).value.minutes + tuckˑfnˑlapFrom(tuckˑvˑnext.value, start))

proc tuckˑfnˑlapMinutes*(start: SlabRef): int =
  var tuckˑvˑnext = tuckSlabCell(tuckˑslabˑStops, start).value.next
  if not tuckˑvˑnext.ok:
    if true:
      return tuckSlabCell(tuckˑslabˑStops, start).value.minutes
  return (tuckSlabCell(tuckˑslabˑStops, start).value.minutes + tuckˑfnˑlapFrom(tuckˑvˑnext.value, start))

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑlist = tuckˑfnˑemptyList()
  var tuckˑvˑa = tuckˑfnˑpushBack(tuckˑvˑlist, 10)
  var tuckˑvˑb = tuckˑfnˑpushBack(tuckˑvˑlist, 20)
  var tuckˑvˑc = tuckˑfnˑpushBack(tuckˑvˑlist, 30)
  var tuckˑvˑd = tuckˑfnˑpushBack(tuckˑvˑlist, 40)
  tuckˑfnˑremove(tuckˑvˑb)
  if (tuckˑfnˑsumForward(tuckˑvˑlist) != 80):
    if true:
      return 1
  if (tuckˑfnˑsumBackward(tuckˑvˑlist) != 80):
    if true:
      return 2
  if tuckSlabLive(tuckˑslabˑNodes, tuckˑvˑb):
    if true:
      return 3
  if not tuckSlabLive(tuckˑslabˑNodes, tuckˑvˑc):
    if true:
      return 4
  var tuckˑvˑroot = tuckSlabNew(tuckˑslabˑDirs, tuckˑtypeˑDir(bytes: 0, parent: TuckResult[SlabRef](status: tsAbsent)))
  var tuckˑvˑsrc = tuckSlabNew(tuckˑslabˑDirs, tuckˑtypeˑDir(bytes: 0, parent: TuckResult[SlabRef](status: tsOk, value: tuckˑvˑroot)))
  var tuckˑvˑlib = tuckSlabNew(tuckˑslabˑDirs, tuckˑtypeˑDir(bytes: 0, parent: TuckResult[SlabRef](status: tsOk, value: tuckˑvˑsrc)))
  tuckˑfnˑaddFile(tuckˑvˑlib, 3)
  tuckˑfnˑaddFile(tuckˑvˑlib, 4)
  if ((tuckSlabCell(tuckˑslabˑDirs, tuckˑvˑroot).value.bytes != 7) or ((tuckSlabCell(tuckˑslabˑDirs, tuckˑvˑsrc).value.bytes != 7) or (tuckSlabCell(tuckˑslabˑDirs, tuckˑvˑlib).value.bytes != 7))):
    if true:
      return 5
  if (tuckˑfnˑdepth(tuckˑvˑlib) != 2):
    if true:
      return 6
  var tuckˑvˑs1 = tuckSlabNew(tuckˑslabˑStops, tuckˑtypeˑStop(minutes: 5, next: TuckResult[SlabRef](status: tsAbsent)))
  var tuckˑvˑs2 = tuckSlabNew(tuckˑslabˑStops, tuckˑtypeˑStop(minutes: 7, next: TuckResult[SlabRef](status: tsOk, value: tuckˑvˑs1)))
  var tuckˑvˑs3 = tuckSlabNew(tuckˑslabˑStops, tuckˑtypeˑStop(minutes: 9, next: TuckResult[SlabRef](status: tsOk, value: tuckˑvˑs2)))
  tuckSlabCell(tuckˑslabˑStops, tuckˑvˑs1).value.next = TuckResult[SlabRef](status: tsOk, value: tuckˑvˑs3)
  if (tuckˑfnˑlapMinutes(tuckˑvˑs1) != 21):
    if true:
      return 7
  tuckSlabReset(tuckˑslabˑStops)
  if tuckSlabLive(tuckˑslabˑStops, tuckˑvˑs1):
    if true:
      return 8
  tuckSlabReset(tuckˑslabˑNodes)
  if (tuckSlabLive(tuckˑslabˑNodes, tuckˑvˑa) or tuckSlabLive(tuckˑslabˑNodes, tuckˑvˑd)):
    if true:
      return 9
  return 0

