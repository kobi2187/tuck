{.experimental: "codeReordering".}

proc tuckˑfnˑcount*(xs: sink seq[tuckˑobjectˑDog]): int
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


proc tuckˑfnˑcount*(xs: sink seq[tuckˑobjectˑDog]): int =
  var tuckˑvˑs = 0
  for tuckˑvˑd in xs:
    if true:
      tuckˑvˑs = (tuckˑvˑs + 1)
  return tuckˑvˑs

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑa = tuckˑobjectˑDog(name: "rex")
  var tuckˑvˑb = tuckˑobjectˑDog(name: "fido")
  return tuckˑfnˑcount(@[tuckˑvˑa, tuckˑvˑb])

