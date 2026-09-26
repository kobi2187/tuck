module _15_type_attributes;

import rt = tuck_rt;
import std.stdio : writeln, stderr;

struct TRec_value(T_value) {
    T_value value;
}

struct tuck_type_EthernetFrame {
    ubyte[6] dst;
    ubyte[6] src;
    ushort ethertype;
}

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

struct tuck_type_UartDriver {
    // no state
}

__gshared tuck_type_UartDriver tuck_type_UartDriverSingleton;


rt.TuckResult!(TRec_value!(ushort)) tuck_fn_readSensor(T)(T payload) {
    stderr.writeln("TUCK PENDING: tuck_fn_readSensor invoked (not implemented)");
    return typeof(return).init;
}

