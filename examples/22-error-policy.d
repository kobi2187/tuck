module _22_error_policy;

import rt = tuck_rt;

struct TRec_value_B36B {
    ushort value;
}

void tuck_unhandled(ushort code, string site) {
    rt.tuckReportUnhandled(code, site);
}

rt.TuckResult!(TRec_value_B36B) tuck_readSensor(ubyte port) {
    if ((port > 3)) {
        return rt.terr!(TRec_value_B36B)(0x2DDC /* badPort */);
    }
    return rt.tok(TRec_value_B36B(value: cast(ushort)(42)));
}

long tuck_poll(ubyte port) {
    { auto tuckDrop1 = tuck_readSensor(port);
      if (tuckDrop1.status != rt.TuckStatus.Ok) { tuck_unhandled(tuckDrop1.err, "poll line 18"); } }
    return 0;
}

