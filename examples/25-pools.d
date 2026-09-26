module _25_pools;

import rt = tuck_rt;

__gshared rt.ObjectPool!(ubyte[512], 4) tuckˑpoolˑRxBuffers;

struct tuckˑtypeˑSession {
    uint clientId;
    uint bytesIn;
}

__gshared rt.ObjectPool!(tuckˑtypeˑSession, 64) tuckˑpoolˑSessions;

struct tuckˑtypeˑSensorReading {
    ubyte channel;
    ushort value;
}

__gshared rt.ObjectPool!(tuckˑtypeˑSensorReading, 16) tuckˑpoolˑReadings;

long tuckˑfnˑadmit(uint id) {
    rt.TuckResult!(rt.PoolHandle) tuckˑvˑs = rt.acquire(tuckˑpoolˑSessions);
    if ((tuckˑvˑs.status == rt.TuckStatus.Ok)) {
        return 1L;
    }
    return 0L;
}

long tuckˑfnˑdrainOnce() {
    rt.TuckResult!(rt.PoolHandle) tuckˑvˑb = rt.acquire(tuckˑpoolˑRxBuffers);
    if ((tuckˑvˑb.status == rt.TuckStatus.Ok)) {
        rt.release(tuckˑpoolˑRxBuffers, tuckˑvˑb.value);
        return 1L;
    }
    return 0L;
}

long tuckˑfnˑmain() {
    long tuckˑvˑadmitted = 0L;
    tuckˑvˑadmitted = (tuckˑvˑadmitted + tuckˑfnˑadmit(1L));
    tuckˑvˑadmitted = (tuckˑvˑadmitted + tuckˑfnˑadmit(2L));
    tuckˑvˑadmitted = (tuckˑvˑadmitted + tuckˑfnˑadmit(3L));
    long tuckˑvˑdrained = tuckˑfnˑdrainOnce();
    return (tuckˑvˑadmitted + tuckˑvˑdrained);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuckˑfnˑmain();
    return cast(int) mainRc;
}
