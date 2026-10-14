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
    rt.TuckResult!(rt.PoolHandle) tuckˑvˑs = rt.tuckPoolAcquire(tuckˑpoolˑSessions);
    if ((tuckˑvˑs.status == rt.TuckStatus.Ok)) {
        return 1L;
    }
    return 0L;
}

extern (C) void memset(ubyte* p, long c, long n);


long tuckˑfnˑdrainOnce() {
    rt.TuckResult!(rt.PoolHandle) tuckˑvˑb = rt.tuckPoolAcquire(tuckˑpoolˑRxBuffers);
    if (!(tuckˑvˑb.status == rt.TuckStatus.Ok)) {
        return 0L;
    }
    ubyte* tuckˑvˑdst = rt.tuckPoolAddr(tuckˑpoolˑRxBuffers, tuckˑvˑb.value);
    scope(exit) rt.tuckDrop(tuckˑvˑdst);
    memset(tuckˑvˑdst, 1L, 512L);
    rt.TuckResult!(ubyte[512]) tuckˑvˑrx = rt.tuckPoolRead(tuckˑpoolˑRxBuffers, tuckˑvˑb.value);
    scope(exit) rt.tuckDrop(tuckˑvˑrx);
    rt.tuckPoolRelease(tuckˑpoolˑRxBuffers, tuckˑvˑb.value);
    if (!(tuckˑvˑrx.status == rt.TuckStatus.Ok)) {
        return 0L;
    }
    ubyte[512] tuckˑvˑbytes = tuckˑvˑrx.value;
    scope(exit) rt.tuckDrop(tuckˑvˑbytes);
    tuckˑvˑrx.value = typeof(tuckˑvˑrx.value).init;
    if ((rt.tuckArrayAt(tuckˑvˑbytes, 511L) != cast(ubyte)1)) {
        return 0L;
    }
    rt.TuckResult!(rt.PoolHandle) tuckˑvˑr = rt.tuckPoolAcquire(tuckˑpoolˑReadings);
    if (!(tuckˑvˑr.status == rt.TuckStatus.Ok)) {
        return 0L;
    }
    tuckˑtypeˑSensorReading tuckˑvˑreading = tuckˑtypeˑSensorReading(channel: cast(ubyte)2, value: cast(ushort)700);
    rt.tuckPoolWrite(tuckˑpoolˑReadings, tuckˑvˑr.value, tuckˑvˑreading);
    rt.TuckResult!(tuckˑtypeˑSensorReading) tuckˑvˑback = rt.tuckPoolRead(tuckˑpoolˑReadings, tuckˑvˑr.value);
    rt.tuckPoolRelease(tuckˑpoolˑReadings, tuckˑvˑr.value);
    if ((tuckˑvˑback.status == rt.TuckStatus.Ok)) {
        return 1L;
    }
    return 0L;
}

long tuckˑfnˑmain() {
    long tuckˑvˑadmitted = 0L;
    tuckˑvˑadmitted = (tuckˑvˑadmitted + tuckˑfnˑadmit(cast(uint)1));
    tuckˑvˑadmitted = (tuckˑvˑadmitted + tuckˑfnˑadmit(cast(uint)2));
    tuckˑvˑadmitted = (tuckˑvˑadmitted + tuckˑfnˑadmit(cast(uint)3));
    long tuckˑvˑdrained = tuckˑfnˑdrainOnce();
    return (tuckˑvˑadmitted + tuckˑvˑdrained);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckLeakMark();
    auto mainRc = tuckˑfnˑmain();
    return rt.tuckLeakCheck(cast(int) mainRc);
}
