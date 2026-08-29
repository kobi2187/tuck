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


proc tuck_total*(xs: seq[Animal]): int =
  var s = 0
  for a in xs:
    if true:
      s = (s + (block:
        case a.tag
        of Animal_is_tuck_Cat:
          var tmp = a.tuck_CatVal
          noise(tmp)
        of Animal_is_tuck_Dog:
          var tmp = a.tuck_DogVal
          noise(tmp)))
  return s

proc tuck_main*(): int =
  var d = tuck_Dog(name: "rex")
  var c = tuck_Cat(lives: 9)
  return tuck_total(@[Animal(tag: Animal_is_tuck_Cat, tuck_CatVal: c), Animal(tag: Animal_is_tuck_Dog, tuck_DogVal: d)])

