{.experimental: "codeReordering".}
import ../compiler/tuck_rt

type tuckˑtypeˑEthernetFrame* = object
  dst*: array[6, uint8]
  src*: array[6, uint8]
  ethertype*: uint16

type tuckˑtypeˑTemperature* = object
  celsius*: float32

proc validate*(self: tuckˑtypeˑTemperature) =
  when not defined(tuckNoInvariants):
    if not ((self.celsius >= -273.15)): tuckInvariantFailed("(self.celsius >= -273.15)", "tuckˑtypeˑTemperature")

type tuckˑactorˑUartDriver* = ref object
  discard

proc tuckˑfnˑreadSensor*[T](payload: T): TuckResult[tuple[value: uint16]] =
  stderr.writeLine("TUCK PENDING: readSensor invoked (not implemented)")

