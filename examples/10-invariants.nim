{.experimental: "codeReordering".}
import ../compiler/tuck_rt

type tuckˑtypeˑTemperature* = object
  celsius*: float32

proc validate*(self: tuckˑtypeˑTemperature) =
  when not defined(tuckNoInvariants):
    if not ((self.celsius >= -273.15)): tuckInvariantFailed("(self.celsius >= -273.15)", "tuckˑtypeˑTemperature")

