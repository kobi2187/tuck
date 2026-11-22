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

# A PRECISE fault for `tuck decode-crash`: an unaligned 32-bit store. The board
# startup sets CCR.UNALIGN_TRP, so Cortex-M traps AT this instruction and the
# stacked PC/LR are trustworthy. Called directly from a Tuck statement, LR is
# the Tuck call site — the line a developer needs to edit. The register-based
# route used an inline runtime helper, whose LR named the helper's Nim line
# instead of the Tuck call.
proc preciseFaultStore*() =
  let p = cast[ptr uint32](0x40000001'u32)
  p[] = 0xdeadbeef'u32
