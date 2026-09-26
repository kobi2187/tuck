{.experimental: "codeReordering".}

proc tuckˑfnˑpick*(a: Animal): Animal
proc tuckˑfnˑmakeOne*(): Animal
proc tuckˑfnˑhear*(a: Animal): int
proc tuckˑfnˑmain*(): int

type tuckˑobjectˑDog* = object
  name*: string

type tuckˑobjectˑCat* = object
  lives*: int

type AnimalTag* = enum Animal_is_tuckˑobjectˑCat, Animal_is_tuckˑobjectˑDog

type Animal* = object
  case tag*: AnimalTag
  of Animal_is_tuckˑobjectˑCat: tuckˑobjectˑCatVal*: tuckˑobjectˑCat
  of Animal_is_tuckˑobjectˑDog: tuckˑobjectˑDogVal*: tuckˑobjectˑDog

proc tuckˑobjectˑDog_noise*(self: var tuckˑobjectˑDog): int =
  return 1


proc tuckˑobjectˑCat_noise*(self: var tuckˑobjectˑCat): int =
  return 41


proc tuckˑfnˑpick*(a: Animal): Animal =
  return a

proc tuckˑfnˑmakeOne*(): Animal =
  var tuckˑvˑd = tuckˑobjectˑDog(name: "rex")
  return tuckˑfnˑpick(Animal(tag: Animal_is_tuckˑobjectˑDog, tuckˑobjectˑDogVal: tuckˑvˑd))

proc tuckˑfnˑhear*(a: Animal): int =
  return (block:
    case a.tag
    of Animal_is_tuckˑobjectˑCat:
      var tmp = a.tuckˑobjectˑCatVal
      tuckˑobjectˑCat_noise(tmp)
    of Animal_is_tuckˑobjectˑDog:
      var tmp = a.tuckˑobjectˑDogVal
      tuckˑobjectˑDog_noise(tmp))

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑa = tuckˑfnˑmakeOne()
  return tuckˑfnˑhear(tuckˑvˑa)

