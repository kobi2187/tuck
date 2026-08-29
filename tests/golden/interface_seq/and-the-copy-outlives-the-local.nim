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


proc tuck_pick*(a: Animal): Animal =
  return a

proc tuck_makeOne*(): Animal =
  var d = tuck_Dog(name: "rex")
  return tuck_pick(Animal(tag: Animal_is_tuck_Dog, tuck_DogVal: d))

proc tuck_hear*(a: Animal): int =
  return (block:
    case a.tag
    of Animal_is_tuck_Cat:
      var tmp = a.tuck_CatVal
      noise(tmp)
    of Animal_is_tuck_Dog:
      var tmp = a.tuck_DogVal
      noise(tmp))

proc tuck_main*(): int =
  var a = tuck_makeOne()
  return tuck_hear(a)

