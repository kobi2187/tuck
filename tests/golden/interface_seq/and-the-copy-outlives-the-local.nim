{.experimental: "codeReordering".}

proc tuck_fn_pick*(a: Animal): Animal
proc tuck_fn_makeOne*(): Animal
proc tuck_fn_hear*(a: Animal): int
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


proc tuck_fn_pick*(a: Animal): Animal =
  return a

proc tuck_fn_makeOne*(): Animal =
  var tuck_d = tuck_type_Dog(name: "rex")
  return tuck_fn_pick(Animal(tag: Animal_is_tuck_type_Dog, tuck_type_DogVal: tuck_d))

proc tuck_fn_hear*(a: Animal): int =
  return (block:
    case a.tag
    of Animal_is_tuck_type_Cat:
      var tmp = a.tuck_type_CatVal
      tuck_type_Cat_noise(tmp)
    of Animal_is_tuck_type_Dog:
      var tmp = a.tuck_type_DogVal
      tuck_type_Dog_noise(tmp))

proc tuck_fn_main*(): int =
  var tuck_a = tuck_fn_makeOne()
  return tuck_fn_hear(tuck_a)

