import ../compiler/tuck_rt

type tuck_Temperature* = object
    celsius*: float32

proc validate*(self: tuck_Temperature) =
  when not defined(release):
    assert((self.celsius >= -273.15), "Invariant violated: (self.celsius >= -273.15)")

