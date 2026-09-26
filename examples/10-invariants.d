module _10_invariants;

import rt = tuck_rt;

struct tuckˑtypeˑTemperature {
    float celsius;
}

void validate_tuckˑtypeˑTemperature(tuckˑtypeˑTemperature self)
{
    version (tuckNoInvariants) {} else
    {
        if (!((self.celsius >= -273.15)))
            rt.tuckInvariantFailed("(self.celsius >= -273.15)", "tuckˑtypeˑTemperature");
    }
}

tuckˑtypeˑTemperature __validated_tuckˑtypeˑTemperature(tuckˑtypeˑTemperature v)
{
    validate_tuckˑtypeˑTemperature(v);
    return v;
}

