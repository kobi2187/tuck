{.experimental: "codeReordering".}

type tuck_Dog* = object
  name*: string

type tuck_Cat* = object
  lives*: int

type AnimalTag* = enum Animal_is_tuck_Cat, Animal_is_tuck_Dog

type Animal* = object
  case tag*: AnimalTag
  of Animal_is_tuck_Cat: tuck_CatVal*: tuck_Cat
  of Animal_is_tuck_Dog: tuck_DogVal*: tuck_Dog

proc noise*(self: var tuck_Dog): int =
  return 1


proc noise*(self: var tuck_Cat): int =
  return 41


proc tuck_count*(xs: seq[tuck_Dog]): int =
  var s = 0
  for d in xs:
    if true:
      s = (s + 1)
  return s

proc tuck_main*(): int =
  var a = tuck_Dog(name: "rex")
  var b = tuck_Dog(name: "fido")
  return tuck_count(@[a, b])

