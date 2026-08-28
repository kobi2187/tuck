module iface3;

import rt = tuck_rt;

enum AnimalTag { Animal_is_tuck_Cat, Animal_is_tuck_Dog }

struct Animal {
    AnimalTag tag;
    tuck_Cat tuck_CatVal;
    tuck_Dog tuck_DogVal;
}

struct tuck_Dog {
    long volume;
}

long tuck_Dog_noise(ref tuck_Dog self) {
    return self.volume;
}


struct tuck_Cat {
    long volume;
}

long tuck_Cat_noise(ref tuck_Cat self) {
    return (self.volume * 100);
}


long tuck_hear(Animal a) {
    return ((Animal v) {
    switch (v.tag) {
        case AnimalTag.Animal_is_tuck_Cat:
            auto tmp = v.tuck_CatVal;
            return tuck_Cat_noise(tmp);
        case AnimalTag.Animal_is_tuck_Dog:
            auto tmp = v.tuck_DogVal;
            return tuck_Dog_noise(tmp);
        default: assert(0, "unreachable interface tag");
    }
})(a);
}

long tuck_report(tuck_Dog d, tuck_Cat c) {
    tuck_Dog dd = d;
    long n1 = tuck_hear(Animal(AnimalTag.Animal_is_tuck_Dog, tuck_DogVal: dd));
    dd.volume = 9;
    long n2 = tuck_hear(Animal(AnimalTag.Animal_is_tuck_Dog, tuck_DogVal: dd));
    long n3 = tuck_hear(Animal(AnimalTag.Animal_is_tuck_Cat, tuck_CatVal: c));
    return (n1 + n2);
}

long tuck_main() {
    tuck_Dog d = tuck_Dog(volume: 3);
    tuck_Cat c = tuck_Cat(volume: 5);
    return tuck_report(d, c);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_main();
    return cast(int) mainRc;
}
