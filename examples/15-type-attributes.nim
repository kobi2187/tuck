{.experimental: "codeReordering".}
import ../compiler/tuck_rt

type tuck_EthernetFrame* = object
  dst*: array[6, uint8]
  src*: array[6, uint8]
  ethertype*: uint16

type tuck_Temperature* = object
  celsius*: float32

proc validate*(self: tuck_Temperature) =
  when not defined(tuckNoInvariants):
    if not ((self.celsius >= -273.15)): tuckInvariantFailed("(self.celsius >= -273.15)", "tuck_Temperature")

type tuck_UartDriver* = ref object
  discard

proc tuck_readSensor*(port: uint8): TuckResult[tuple[value: uint16]] =
  discard

