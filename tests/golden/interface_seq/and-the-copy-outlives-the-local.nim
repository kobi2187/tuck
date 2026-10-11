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

proc tuckDrop*(x: var Animal) =
  case x.tag
  of Animal_is_tuckˑobjectˑCat: tuckDrop(x.tuckˑobjectˑCatVal)
  of Animal_is_tuckˑobjectˑDog: tuckDrop(x.tuckˑobjectˑDogVal)

proc tuckˑobjectˑDogˑnoise*(self: tuckˑobjectˑDog): int =
  return 1


proc tuckˑobjectˑCatˑnoise*(self: tuckˑobjectˑCat): int =
  return 41


proc tuckˑfnˑpick*(a: Animal): Animal =
  var a = tuckBits(a)
  return tuckMove(a)

proc tuckˑfnˑmakeOne*(): Animal =
  var tuckˑvˑd = tuckˑobjectˑDog(name: tuckCopy("rex"))
  return tuckˑfnˑpick(Animal(tag: Animal_is_tuckˑobjectˑDog, tuckˑobjectˑDogVal: tuckMove(tuckˑvˑd)))

proc tuckˑfnˑhear*(a: Animal): int =
  return (block:
    case a.tag
    of Animal_is_tuckˑobjectˑCat:
      template tmp: untyped {.used.} = a.tuckˑobjectˑCatVal
      tuckˑobjectˑCatˑnoise(tmp)
    of Animal_is_tuckˑobjectˑDog:
      template tmp: untyped {.used.} = a.tuckˑobjectˑDogVal
      tuckˑobjectˑDogˑnoise(tmp))

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑa = tuckˑfnˑmakeOne()
  defer: tuckDrop(tuckˑvˑa)
  return tuckˑfnˑhear(tuckˑvˑa)

