# Trigger a HardFault under QEMU by calling through a null pointer.
proc faultWrite*() =
  let p = cast[proc () {.nimcall.}](nil)
  p()
