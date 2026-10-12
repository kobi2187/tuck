{.experimental: "codeReordering".}

proc tuckˑfnˑtotal*(xs: seq[Animal]): int
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


proc tuckˑfnˑtotal*(xs: seq[Animal]): int =
  var tuckˑvˑs = 0
  for tuckˑvˑa in xs:
    if true:
      tuckˑvˑs = (tuckˑvˑs + (block:
        case tuckˑvˑa.tag
        of Animal_is_tuckˑobjectˑCat:
          template tmp: untyped {.used.} = tuckˑvˑa.tuckˑobjectˑCatVal
          tuckˑobjectˑCatˑnoise(tmp)
        of Animal_is_tuckˑobjectˑDog:
          template tmp: untyped {.used.} = tuckˑvˑa.tuckˑobjectˑDogVal
          tuckˑobjectˑDogˑnoise(tmp)))
  return tuckˑvˑs

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑd = tuckˑobjectˑDog(name: tuckCopy("rex"))
  var tuckˑvˑc = tuckˑobjectˑCat(lives: 9)
  var tuckOwnTmp1 = @[Animal(tag: Animal_is_tuckˑobjectˑDog, tuckˑobjectˑDogVal: tuckMove(tuckˑvˑd)), Animal(tag: Animal_is_tuckˑobjectˑCat, tuckˑobjectˑCatVal: tuckˑvˑc)]
  defer: tuckDrop(tuckOwnTmp1)
  return tuckˑfnˑtotal(tuckOwnTmp1)

