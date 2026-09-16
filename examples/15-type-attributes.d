module _15_type_attributes;

import rt = tuck_rt;
import std.stdio : writeln, stderr;

struct TRec_value(T_value) {
    T_value value;
}

struct tuck_EthernetFrame {
    ubyte[6] dst;
    ubyte[6] src;
    ushort ethertype;
}

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

struct tuck_UartDriver {
    // no state
}

__gshared tuck_UartDriver tuck_UartDriverSingleton;


rt.TuckResult!(TRec_value!(ushort)) tuck_readSensor(T)(T payload) {
    stderr.writeln("TUCK PENDING: tuck_readSensor invoked (not implemented)");
    return typeof(return).init;
}

