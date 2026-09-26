{.experimental: "codeReordering".}

proc tuckˑfnˑmakeMany*(): seq[Animal]
proc tuckˑfnˑtotal*(xs: sink seq[Animal]): int
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

proc tuckˑobjectˑDogˑnoise*(self: var tuckˑobjectˑDog): int =
  return 1


proc tuckˑobjectˑCatˑnoise*(self: var tuckˑobjectˑCat): int =
  return 41


proc tuckˑfnˑmakeMany*(): seq[Animal] =
  var tuckˑvˑd = tuckˑobjectˑDog(name: "rex")
  var tuckˑvˑc = tuckˑobjectˑCat(lives: 9)
  return @[Animal(tag: Animal_is_tuckˑobjectˑDog, tuckˑobjectˑDogVal: tuckˑvˑd), Animal(tag: Animal_is_tuckˑobjectˑCat, tuckˑobjectˑCatVal: tuckˑvˑc)]

proc tuckˑfnˑtotal*(xs: sink seq[Animal]): int =
  var tuckˑvˑs = 0
  for tuckˑvˑa in xs:
    if true:
      tuckˑvˑs = (tuckˑvˑs + (block:
        case tuckˑvˑa.tag
        of Animal_is_tuckˑobjectˑCat:
          var tmp = tuckˑvˑa.tuckˑobjectˑCatVal
          tuckˑobjectˑCatˑnoise(tmp)
        of Animal_is_tuckˑobjectˑDog:
          var tmp = tuckˑvˑa.tuckˑobjectˑDogVal
          tuckˑobjectˑDogˑnoise(tmp)))
  return tuckˑvˑs

proc tuckˑfnˑmain*(): int =
  return tuckˑfnˑtotal(tuckˑfnˑmakeMany())

