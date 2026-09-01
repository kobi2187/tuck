module _25_pools;

import rt = tuck_rt;

__gshared rt.ObjectPool!(ubyte[512], 4) tuck_RxBuffers;

struct tuck_Session {
    uint clientId;
    uint bytesIn;
}

__gshared rt.ObjectPool!(tuck_Session, 64) tuck_Sessions;

struct tuck_SensorReading {
    ubyte channel;
    ushort value;
}

__gshared rt.ObjectPool!(tuck_SensorReading, 16) tuck_Readings;

long tuck_admit(uint id) {
    rt.TuckResult!(tuck_Session) s = rt.acquire(tuck_Sessions);
    if ((s.status == rt.TuckStatus.Ok)) {
        return 1;
    }
    return 0;
}

long tuck_drainOnce() {
    rt.TuckResult!(ubyte[512]) b = rt.acquire(tuck_RxBuffers);
    if ((b.status == rt.TuckStatus.Ok)) {
        rt.release(tuck_RxBuffers, b.value);
        return 1;
    }
    return 0;
}

long tuck_main() {
    long admitted = 0;
    admitted = (admitted + tuck_admit(1));
    admitted = (admitted + tuck_admit(2));
    admitted = (admitted + tuck_admit(3));
    long drained = tuck_drainOnce();
    return (admitted + drained);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_main();
    return cast(int) mainRc;
}
