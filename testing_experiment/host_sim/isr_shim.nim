# Tuck-facing names for the runtime's ISR-safe SPSC slot.
import ../../compiler/tuck_sl

proc isrPost*(slot: int, value: int) =
  tuckIsrPost(slot, value)

proc isrTake*(slot: int): int =
  tuckIsrTake(slot)
