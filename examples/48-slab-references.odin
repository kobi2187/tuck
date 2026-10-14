#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"

tuckˑtypeˑNode :: struct {
	data: int,
	prev: rt.TuckResult(rt.SlabRef),
	next: rt.TuckResult(rt.SlabRef),
}

tuckˑslabˑNodes := rt.SlabChunked(tuckˑtypeˑNode){name = "Nodes"}

tuckˑfnˑemptyList :: proc () -> rt.SlabRef {
  tuckˑvˑs := rt.tuckSlabNew(&tuckˑslabˑNodes, tuckˑtypeˑNode{data = 0, prev = rt.tnone(rt.SlabRef), next = rt.tnone(rt.SlabRef)})
  rt.tuckSlabCell(&tuckˑslabˑNodes, tuckˑvˑs).value.prev = rt.TuckResult(rt.SlabRef){status = .Ok, value = tuckˑvˑs}
  rt.tuckSlabCell(&tuckˑslabˑNodes, tuckˑvˑs).value.next = rt.TuckResult(rt.SlabRef){status = .Ok, value = tuckˑvˑs}
  return tuckˑvˑs
}

tuckˑfnˑafter :: proc (n: rt.SlabRef) -> rt.SlabRef {
  tuckˑvˑx := rt.tuckSlabCell(&tuckˑslabˑNodes, n).value.next
  if (tuckˑvˑx.status == .Ok) {
      return tuckˑvˑx.value
  }
  return n
}

tuckˑfnˑbefore :: proc (n: rt.SlabRef) -> rt.SlabRef {
  tuckˑvˑx := rt.tuckSlabCell(&tuckˑslabˑNodes, n).value.prev
  if (tuckˑvˑx.status == .Ok) {
      return tuckˑvˑx.value
  }
  return n
}

tuckˑfnˑpushBack :: proc (list: rt.SlabRef, data: int) -> rt.SlabRef {
  tuckˑvˑlast := tuckˑfnˑbefore(list)
  tuckˑvˑn := rt.tuckSlabNew(&tuckˑslabˑNodes, tuckˑtypeˑNode{data = data, prev = rt.TuckResult(rt.SlabRef){status = .Ok, value = tuckˑvˑlast}, next = rt.TuckResult(rt.SlabRef){status = .Ok, value = list}})
  rt.tuckSlabCell(&tuckˑslabˑNodes, tuckˑvˑlast).value.next = rt.TuckResult(rt.SlabRef){status = .Ok, value = tuckˑvˑn}
  rt.tuckSlabCell(&tuckˑslabˑNodes, list).value.prev = rt.TuckResult(rt.SlabRef){status = .Ok, value = tuckˑvˑn}
  return tuckˑvˑn
}

tuckˑfnˑremove :: proc (n: rt.SlabRef) {
  tuckˑvˑp := tuckˑfnˑbefore(n)
  tuckˑvˑq := tuckˑfnˑafter(n)
  rt.tuckSlabCell(&tuckˑslabˑNodes, tuckˑvˑp).value.next = rt.TuckResult(rt.SlabRef){status = .Ok, value = tuckˑvˑq}
  rt.tuckSlabCell(&tuckˑslabˑNodes, tuckˑvˑq).value.prev = rt.TuckResult(rt.SlabRef){status = .Ok, value = tuckˑvˑp}
  rt.tuckSlabFree(&tuckˑslabˑNodes, n)
}

tuckˑfnˑsumForward :: proc (list: rt.SlabRef) -> int {
  tuckˑvˑtotal := 0
  tuckˑvˑcur := tuckˑfnˑafter(list)
  for (tuckˑvˑcur != list) {
      tuckˑvˑtotal = (tuckˑvˑtotal + rt.tuckSlabCell(&tuckˑslabˑNodes, tuckˑvˑcur).value.data)
      tuckˑvˑcur = tuckˑfnˑafter(tuckˑvˑcur)
  }
  return tuckˑvˑtotal
}

tuckˑfnˑsumBackward :: proc (list: rt.SlabRef) -> int {
  tuckˑvˑtotal := 0
  tuckˑvˑcur := tuckˑfnˑbefore(list)
  for (tuckˑvˑcur != list) {
      tuckˑvˑtotal = (tuckˑvˑtotal + rt.tuckSlabCell(&tuckˑslabˑNodes, tuckˑvˑcur).value.data)
      tuckˑvˑcur = tuckˑfnˑbefore(tuckˑvˑcur)
  }
  return tuckˑvˑtotal
}

tuckˑtypeˑDir :: struct {
	bytes: int,
	parent: rt.TuckResult(rt.SlabRef),
}

tuckˑslabˑDirs := rt.SlabChunked(tuckˑtypeˑDir){name = "Dirs"}

tuckˑfnˑaddFile :: proc (dir: rt.SlabRef, bytes: int) {
  rt.tuckSlabCell(&tuckˑslabˑDirs, dir).value.bytes = (rt.tuckSlabCell(&tuckˑslabˑDirs, dir).value.bytes + bytes)
  tuckˑvˑup := rt.tuckSlabCell(&tuckˑslabˑDirs, dir).value.parent
  if (tuckˑvˑup.status == .Ok) {
      tuckˑfnˑaddFile(tuckˑvˑup.value, bytes)
  }
}

tuckˑfnˑdepth :: proc (dir: rt.SlabRef) -> int {
  tuckˑvˑup := rt.tuckSlabCell(&tuckˑslabˑDirs, dir).value.parent
  if !(tuckˑvˑup.status == .Ok) {
      return 0
  }
  return (1 + tuckˑfnˑdepth(tuckˑvˑup.value))
}

tuckˑtypeˑStop :: struct {
	minutes: int,
	next: rt.TuckResult(rt.SlabRef),
}

tuckˑslabˑStops := rt.SlabChunked(tuckˑtypeˑStop){name = "Stops"}

tuckˑfnˑlapFrom :: proc (at: rt.SlabRef, start: rt.SlabRef) -> int {
  if (at == start) {
      return 0
  }
  tuckˑvˑnext := rt.tuckSlabCell(&tuckˑslabˑStops, at).value.next
  if !(tuckˑvˑnext.status == .Ok) {
      return rt.tuckSlabCell(&tuckˑslabˑStops, at).value.minutes
  }
  return (rt.tuckSlabCell(&tuckˑslabˑStops, at).value.minutes + tuckˑfnˑlapFrom(tuckˑvˑnext.value, start))
}

tuckˑfnˑlapMinutes :: proc (start: rt.SlabRef) -> int {
  tuckˑvˑnext := rt.tuckSlabCell(&tuckˑslabˑStops, start).value.next
  if !(tuckˑvˑnext.status == .Ok) {
      return rt.tuckSlabCell(&tuckˑslabˑStops, start).value.minutes
  }
  return (rt.tuckSlabCell(&tuckˑslabˑStops, start).value.minutes + tuckˑfnˑlapFrom(tuckˑvˑnext.value, start))
}

tuckˑfnˑmain :: proc () -> int {
  tuckˑvˑlist := tuckˑfnˑemptyList()
  tuckˑvˑa := tuckˑfnˑpushBack(tuckˑvˑlist, 10)
  tuckˑvˑb := tuckˑfnˑpushBack(tuckˑvˑlist, 20)
  tuckˑvˑc := tuckˑfnˑpushBack(tuckˑvˑlist, 30)
  tuckˑvˑd := tuckˑfnˑpushBack(tuckˑvˑlist, 40)
  tuckˑfnˑremove(tuckˑvˑb)
  if (tuckˑfnˑsumForward(tuckˑvˑlist) != 80) {
      return 1
  }
  if (tuckˑfnˑsumBackward(tuckˑvˑlist) != 80) {
      return 2
  }
  if rt.tuckSlabLive(&tuckˑslabˑNodes, tuckˑvˑb) {
      return 3
  }
  if !rt.tuckSlabLive(&tuckˑslabˑNodes, tuckˑvˑc) {
      return 4
  }
  tuckˑvˑroot := rt.tuckSlabNew(&tuckˑslabˑDirs, tuckˑtypeˑDir{bytes = 0, parent = rt.tnone(rt.SlabRef)})
  tuckˑvˑsrc := rt.tuckSlabNew(&tuckˑslabˑDirs, tuckˑtypeˑDir{bytes = 0, parent = rt.TuckResult(rt.SlabRef){status = .Ok, value = tuckˑvˑroot}})
  tuckˑvˑlib := rt.tuckSlabNew(&tuckˑslabˑDirs, tuckˑtypeˑDir{bytes = 0, parent = rt.TuckResult(rt.SlabRef){status = .Ok, value = tuckˑvˑsrc}})
  tuckˑfnˑaddFile(tuckˑvˑlib, 3)
  tuckˑfnˑaddFile(tuckˑvˑlib, 4)
  if ((rt.tuckSlabCell(&tuckˑslabˑDirs, tuckˑvˑroot).value.bytes != 7) || ((rt.tuckSlabCell(&tuckˑslabˑDirs, tuckˑvˑsrc).value.bytes != 7) || (rt.tuckSlabCell(&tuckˑslabˑDirs, tuckˑvˑlib).value.bytes != 7))) {
      return 5
  }
  if (tuckˑfnˑdepth(tuckˑvˑlib) != 2) {
      return 6
  }
  tuckˑvˑs1 := rt.tuckSlabNew(&tuckˑslabˑStops, tuckˑtypeˑStop{minutes = 5, next = rt.tnone(rt.SlabRef)})
  tuckˑvˑs2 := rt.tuckSlabNew(&tuckˑslabˑStops, tuckˑtypeˑStop{minutes = 7, next = rt.TuckResult(rt.SlabRef){status = .Ok, value = tuckˑvˑs1}})
  tuckˑvˑs3 := rt.tuckSlabNew(&tuckˑslabˑStops, tuckˑtypeˑStop{minutes = 9, next = rt.TuckResult(rt.SlabRef){status = .Ok, value = tuckˑvˑs2}})
  rt.tuckSlabCell(&tuckˑslabˑStops, tuckˑvˑs1).value.next = rt.TuckResult(rt.SlabRef){status = .Ok, value = tuckˑvˑs3}
  if (tuckˑfnˑlapMinutes(tuckˑvˑs1) != 21) {
      return 7
  }
  rt.tuckSlabReset(&tuckˑslabˑStops)
  if rt.tuckSlabLive(&tuckˑslabˑStops, tuckˑvˑs1) {
      return 8
  }
  rt.tuckSlabReset(&tuckˑslabˑNodes)
  if (rt.tuckSlabLive(&tuckˑslabˑNodes, tuckˑvˑa) || rt.tuckSlabLive(&tuckˑslabˑNodes, tuckˑvˑd)) {
      return 9
  }
  return 0
}

tuckSlabsRelease :: proc() {
	when rt.TUCK_TRACK {
		rt.tuckSlabRelease(&tuckˑslabˑNodes)
		rt.tuckSlabRelease(&tuckˑslabˑDirs)
		rt.tuckSlabRelease(&tuckˑslabˑStops)
	}
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	mainRc := tuckˑfnˑmain()
	rt.tuckSlabReport(&tuckˑslabˑNodes)
	rt.tuckSlabReport(&tuckˑslabˑStops)
	tuckSlabsRelease()
	rt.tuckTrackCheck()
	os.exit(mainRc)
}
