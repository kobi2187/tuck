{.experimental: "codeReordering".}

proc tuck_count*(xs: sink seq[tuck_Dog]): int
proc tuck_main*(): int

type tuck_Dog* = object
  name*: string

type tuck_Cat* = object
  lives*: int

type AnimalTag* = enum Animal_is_tuck_Cat, Animal_is_tuck_Dog

type Animal* = object
  case tag*: AnimalTag
  of Animal_is_tuck_Cat: tuck_CatVal*: tuck_Cat
  of Animal_is_tuck_Dog: tuck_DogVal*: tuck_Dog

proc tuck_Dog_noise*(self: var tuck_Dog): int =
  return 1


proc tuck_Cat_noise*(self: var tuck_Cat): int =
  return 41


proc tuck_count*(xs: sink seq[tuck_Dog]): int =
  var tuck_s = 0
  for tuck_d in xs:
    if true:
      tuck_s = (tuck_s + 1)
  return tuck_s

proc tuck_main*(): int =
  var tuck_a = tuck_Dog(name: "rex")
  var tuck_b = tuck_Dog(name: "fido")
  return tuck_count(@[tuck_a, tuck_b])

