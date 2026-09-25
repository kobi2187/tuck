module _25_pools;

import rt = tuck_rt;

__gshared rt.ObjectPool!(ubyte[512], 4) tuck_RxBuffers;

struct tuck_type_Session {
    uint clientId;
    uint bytesIn;
}

__gshared rt.ObjectPool!(tuck_type_Session, 64) tuck_Sessions;

struct tuck_type_SensorReading {
    ubyte channel;
    ushort value;
}

__gshared rt.ObjectPool!(tuck_type_SensorReading, 16) tuck_Readings;

long tuck_fn_admit(uint id) {
    rt.TuckResult!(rt.PoolHandle) tuck_s = rt.acquire(tuck_Sessions);
    if ((tuck_s.status == rt.TuckStatus.Ok)) {
        return 1L;
    }
    return 0L;
}

long tuck_fn_drainOnce() {
    rt.TuckResult!(rt.PoolHandle) tuck_b = rt.acquire(tuck_RxBuffers);
    if ((tuck_b.status == rt.TuckStatus.Ok)) {
        rt.release(tuck_RxBuffers, tuck_b.value);
        return 1L;
    }
    return 0L;
}

long tuck_fn_main() {
    long tuck_admitted = 0L;
    tuck_admitted = (tuck_admitted + tuck_fn_admit(1L));
    tuck_admitted = (tuck_admitted + tuck_fn_admit(2L));
    tuck_admitted = (tuck_admitted + tuck_fn_admit(3L));
    long tuck_drained = tuck_fn_drainOnce();
    return (tuck_admitted + tuck_drained);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_fn_main();
    return cast(int) mainRc;
}
