{.experimental: "codeReordering".}

proc tuck_fn_count*(xs: sink seq[tuck_type_Dog]): int
proc tuck_fn_main*(): int

type tuck_type_Dog* = object
  name*: string

type tuck_type_Cat* = object
  lives*: int

type AnimalTag* = enum Animal_is_tuck_type_Cat, Animal_is_tuck_type_Dog

type Animal* = object
  case tag*: AnimalTag
  of Animal_is_tuck_type_Cat: tuck_type_CatVal*: tuck_type_Cat
  of Animal_is_tuck_type_Dog: tuck_type_DogVal*: tuck_type_Dog

proc tuck_type_Dog_noise*(self: var tuck_type_Dog): int =
  return 1


proc tuck_type_Cat_noise*(self: var tuck_type_Cat): int =
  return 41


proc tuck_fn_count*(xs: sink seq[tuck_type_Dog]): int =
  var tuck_s = 0
  for tuck_d in xs:
    if true:
      tuck_s = (tuck_s + 1)
  return tuck_s

proc tuck_fn_main*(): int =
  var tuck_a = tuck_type_Dog(name: "rex")
  var tuck_b = tuck_type_Dog(name: "fido")
  return tuck_fn_count(@[tuck_a, tuck_b])

