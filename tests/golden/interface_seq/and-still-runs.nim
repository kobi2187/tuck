{.experimental: "codeReordering".}

proc tuckˑfnˑcount*(xs: seq[tuckˑobjectˑDog]): int
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


proc tuckˑfnˑcount*(xs: seq[tuckˑobjectˑDog]): int =
  var tuckˑvˑs = 0
  for tuckˑvˑd in xs:
    if true:
      tuckˑvˑs = (tuckˑvˑs + 1)
  return tuckˑvˑs

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑa = tuckˑobjectˑDog(name: tuckCopy("rex"))
  var tuckˑvˑb = tuckˑobjectˑDog(name: tuckCopy("fido"))
  var tuckOwnTmp1 = @[tuckMove(tuckˑvˑa), tuckMove(tuckˑvˑb)]
  defer: tuckDrop(tuckOwnTmp1)
  return tuckˑfnˑcount(tuckOwnTmp1)

