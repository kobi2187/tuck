#+feature dynamic-literals
package main

TRec_done :: struct ($T_done: typeid) {
	done: T_done,
}

tuckˑtypeˑMilliseconds :: distinct u32

tuckˑfnˑms :: proc (value: u32) -> tuckˑtypeˑMilliseconds {
  return tuckˑtypeˑMilliseconds(value)
}

tuckˑfnˑdelay :: proc (ms: tuckˑtypeˑMilliseconds) -> TRec_done(bool) {
  return TRec_done(bool){done = true}
}

tuckˑfnˑmain :: proc () {
  tuckˑvˑr := tuckˑfnˑdelay(tuckˑfnˑms(u32(5)))
  return
}

main :: proc() {
	tuckˑfnˑmain()
}
