module _10_invariants;

import rt = tuck_rt;

struct tuck_Temperature {
    float celsius;
}

void validate_tuck_Temperature(tuck_Temperature self)
{
    version (tuckNoInvariants) {} else
    {
        if (!((self.celsius >= -273.15)))
            rt.tuckInvariantFailed("(self.celsius >= -273.15)", "tuck_Temperature");
    }
}

tuck_Temperature __validated_tuck_Temperature(tuck_Temperature v)
{
    validate_tuck_Temperature(v);
    return v;
}

