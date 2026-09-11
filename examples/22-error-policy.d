module _22_error_policy;

import rt = tuck_rt;

struct TRec_value(T_value) {
    T_value value;
}

void tuck_unhandled(ushort code, string site) {
    rt.tuckReportUnhandled(code, site);
}

rt.TuckResult!(TRec_value!(ushort)) tuck_readSensor(ubyte port) {
    if ((port > 3L)) {
        return rt.terr!(TRec_value!(ushort))(0x2DDC /* badPort */);
    }
    return rt.tok(TRec_value!(ushort)(value: cast(ushort)(42L)));
}

long tuck_poll(ubyte port) {
    { auto tuckDrop1 = tuck_readSensor(port);
      if (tuckDrop1.status != rt.TuckStatus.Ok) { tuck_unhandled(tuckDrop1.err, "poll line 18"); } }
    return 0L;
}

