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
  var tuckˑvˑa = tuckˑobjectˑDog(name: "rex")
  var tuckˑvˑb = tuckˑobjectˑDog(name: "fido")
  var tuckOwnTmp1 = @[tuckˑvˑa, tuckˑvˑb]
  return tuckˑfnˑcount(tuckOwnTmp1)

