{.experimental: "codeReordering".}

proc tuck_total*(xs: seq[Animal]): int
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


proc tuck_total*(xs: seq[Animal]): int =
  var tuck_s = 0
  for tuck_a in xs:
    if true:
      tuck_s = (tuck_s + (block:
        case tuck_a.tag
        of Animal_is_tuck_Cat:
          var tmp = tuck_a.tuck_CatVal
          tuck_Cat_noise(tmp)
        of Animal_is_tuck_Dog:
          var tmp = tuck_a.tuck_DogVal
          tuck_Dog_noise(tmp)))
  return tuck_s

proc tuck_main*(): int =
  var tuck_d = tuck_Dog(name: "rex")
  var tuck_c = tuck_Cat(lives: 9)
  return tuck_total(@[Animal(tag: Animal_is_tuck_Cat, tuck_CatVal: tuck_c), Animal(tag: Animal_is_tuck_Dog, tuck_DogVal: tuck_d)])

