module _10_invariants;

import rt = tuck_rt;

struct tuck_type_Temperature {
    float celsius;
}

void validate_tuck_type_Temperature(tuck_type_Temperature self)
{
    version (tuckNoInvariants) {} else
    {
        if (!((self.celsius >= -273.15)))
            rt.tuckInvariantFailed("(self.celsius >= -273.15)", "tuck_type_Temperature");
    }
}

tuck_type_Temperature __validated_tuck_type_Temperature(tuck_type_Temperature v)
{
    validate_tuck_type_Temperature(v);
    return v;
}

