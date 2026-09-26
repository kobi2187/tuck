{.experimental: "codeReordering".}

proc tuck_fn_total*(xs: sink seq[Animal]): int
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


proc tuck_fn_total*(xs: sink seq[Animal]): int =
  var tuck_s = 0
  for tuck_a in xs:
    if true:
      tuck_s = (tuck_s + (block:
        case tuck_a.tag
        of Animal_is_tuck_type_Cat:
          var tmp = tuck_a.tuck_type_CatVal
          tuck_type_Cat_noise(tmp)
        of Animal_is_tuck_type_Dog:
          var tmp = tuck_a.tuck_type_DogVal
          tuck_type_Dog_noise(tmp)))
  return tuck_s

proc tuck_fn_main*(): int =
  var tuck_d = tuck_type_Dog(name: "rex")
  var tuck_c = tuck_type_Cat(lives: 9)
  return tuck_fn_total(@[Animal(tag: Animal_is_tuck_type_Cat, tuck_type_CatVal: tuck_c), Animal(tag: Animal_is_tuck_type_Dog, tuck_type_DogVal: tuck_d)])

