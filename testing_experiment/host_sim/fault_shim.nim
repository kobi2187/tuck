# Fault injection shims for QEMU testing. Compile-time: activated by
# -d:TuckFaultIsrDrop. The Tuck program calls these to decide whether to
# simulate a fault at a given point.
proc faultIsrDrop*(): bool =
  when defined(TuckFaultIsrDrop): true else: false

proc faultBitFlip*(): bool =
  when defined(TuckFaultBitFlip): true else: false

proc faultWrite*() =
  let p = cast[proc () {.nimcall.}](nil)
  p()
