# Tuck-facing names for the runtime's ISR-safe SPSC slot.
import ../../../compiler/tuck_sl

proc isrPost*(slot: int, value: int) =
  tuckIsrPost(slot, value)

proc isrTake*(slot: int): int =
  tuckIsrTake(slot)

proc isrOverruns*(slot: int): int =
  tuckIsrOverruns(slot)

proc irqMasked*(): bool =
  ## PRIMASK on metal: true while interrupts are masked. A hosted build has no
  ## interrupts to mask, so it is always false there.
  when defined(freestanding):
    var m: uint32
    {.emit: "__asm volatile(\"mrs %0, primask\" : \"=r\"(`m`));".}
    m != 0
  else:
    false
