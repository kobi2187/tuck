module _15_type_attributes;

import rt = tuck_rt;
import std.stdio : writeln, stderr;

struct TRec_value(T_value) {
    T_value value;
}

struct tuckˑtypeˑEthernetFrame {
    ubyte[6] dst;
    ubyte[6] src;
    ushort ethertype;
}

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

struct tuckˑactorˑUartDriver {
    // no state
}

__gshared tuckˑactorˑUartDriver tuckˑactorˑUartDriverSingleton;


rt.TuckResult!(TRec_value!(ushort)) tuckˑfnˑreadSensor(T)(T payload) {
    stderr.writeln("TUCK PENDING: readSensor invoked (not implemented)");
    return typeof(return).init;
}

