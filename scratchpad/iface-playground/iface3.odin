package main

import "core:os"

AnimalTag :: enum { Animal_is_tuck_Cat, Animal_is_tuck_Dog }

Animal :: struct {
	tag: AnimalTag,
	tuck_CatVal: tuck_Cat,
	tuck_DogVal: tuck_Dog,
}

tuck_Dog :: struct {
	volume: int,
}

tuck_Dog_noise :: proc (self: ^tuck_Dog) -> int {
  return self^.volume
}


tuck_Cat :: struct {
	volume: int,
}

tuck_Cat_noise :: proc (self: ^tuck_Cat) -> int {
  return (self^.volume * 100)
}


tuck_hear :: proc (a: Animal) -> int {
  return (proc(v: Animal) -> int {
	switch v.tag {
		case .Animal_is_tuck_Cat:
			tmp := v.tuck_CatVal
			return tuck_Cat_noise(&tmp)
		case .Animal_is_tuck_Dog:
			tmp := v.tuck_DogVal
			return tuck_Dog_noise(&tmp)
	}
	return 0
})(a)
}

tuck_report :: proc (d: tuck_Dog, c: tuck_Cat) -> int {
  dd := d
  n1 := tuck_hear(Animal{tag = .Animal_is_tuck_Dog, tuck_DogVal = dd})
  dd.volume = 9
  n2 := tuck_hear(Animal{tag = .Animal_is_tuck_Dog, tuck_DogVal = dd})
  n3 := tuck_hear(Animal{tag = .Animal_is_tuck_Cat, tuck_CatVal = c})
  return (n1 + n2)
}

tuck_main :: proc () -> int {
  d := tuck_Dog{volume = 3}
  c := tuck_Cat{volume = 5}
  return tuck_report(d, c)
}

main :: proc() {
	mainRc := tuck_main()
	os.exit(mainRc)
}
