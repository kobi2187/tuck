{.experimental: "codeReordering".}
import ../compiler/tuck_rt

type tuck_type_Temperature* = object
  celsius*: float32

proc validate*(self: tuck_type_Temperature) =
  when not defined(tuckNoInvariants):
    if not ((self.celsius >= -273.15)): tuckInvariantFailed("(self.celsius >= -273.15)", "tuck_type_Temperature")

