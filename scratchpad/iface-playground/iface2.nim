import ../../compiler/tuck_rt
import console

type tuck_Dog* = object
  volume*: int

type tuck_Cat* = object
  volume*: int

type AnimalTag* = enum Animal_is_tuck_Cat, Animal_is_tuck_Dog

type Animal* = object
  case tag*: AnimalTag
  of Animal_is_tuck_Cat: tuck_CatVal*: tuck_Cat
  of Animal_is_tuck_Dog: tuck_DogVal*: tuck_Dog

proc noise*(self: var tuck_Dog): int =
  return self.volume


proc noise*(self: var tuck_Cat): int =
  return (self.volume * 100)


proc tuck_hear*(a: Animal): int =
  return (block:
    case a.tag
    of Animal_is_tuck_Cat:
      var tmp = a.tuck_CatVal
      noise(tmp)
    of Animal_is_tuck_Dog:
      var tmp = a.tuck_DogVal
      noise(tmp))

proc tuck_report*(d: tuck_Dog, c: tuck_Cat): int =
  var dd = d
  var n1 = tuck_hear(Animal(tag: Animal_is_tuck_Dog, tuck_DogVal: dd))
  dd.volume = 9
  var n2 = tuck_hear(Animal(tag: Animal_is_tuck_Dog, tuck_DogVal: dd))
  var n3 = tuck_hear(Animal(tag: Animal_is_tuck_Cat, tuck_CatVal: c))
  printLine(tuckConcat(tuckConcat(tuckConcat(tuckConcat(tuckConcat("n1=", n1.toStr), " n2="), n2.toStr), " n3="), n3.toStr))
  return (n1 + n2)

proc tuck_main*(): int =
  var d = tuck_Dog(volume: 3)
  var c = tuck_Cat(volume: 5)
  return tuck_report(d, c)

