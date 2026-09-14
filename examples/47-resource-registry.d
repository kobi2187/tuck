module _47_resource_registry;

import rt = tuck_rt;
import std.stdio : writeln, stderr;

alias NetHandle = rt.ResourceHandle;
__gshared rt.ResourceTable tuckRes_net = {kind: "net", cap: 10000, policy: rt.RtResourcePolicy.Lazy, onFull: rt.RtOnFull.Error, sweepBatch: 100};
alias FileHandle = rt.ResourceHandle;
__gshared rt.ResourceTable tuckRes_file = {kind: "file", cap: 8, policy: rt.RtResourcePolicy.Strict, onFull: rt.RtOnFull.Absent, sweepBatch: 0, onFinish: &rt.tuckResFlush};
alias UdpHandle = rt.ResourceHandle;
__gshared rt.ResourceTable tuckRes_udp = {kind: "udp", cap: 0, policy: rt.RtResourcePolicy.Lazy, onFull: rt.RtOnFull.Absent, sweepBatch: 0};
void tuckResourcesShutdown() {
    rt.shutdownResources(tuckRes_udp);
    rt.shutdownResources(tuckRes_file);
    rt.shutdownResources(tuckRes_net);
}

long tuck_rawOpenUdp(T)(T payload) {
    stderr.writeln("TUCK PENDING: tuck_rawOpenUdp invoked (not implemented)");
    return typeof(return).init;
}


rt.TuckResult!(UdpHandle) tuck_openUdp(ushort port) {
    return rt.acquireResource(tuckRes_udp, cast(long)(tuck_rawOpenUdp(port)), "47-resource-registry:69");
}

long tuck_withScratch(long n) {
    long tuck_scratch = n;
    scope(exit) {
        tuck_scratch = 0L;
    }
    return (tuck_scratch + 1L);
}

long tuck_serve(ushort port) {
    rt.TuckResult!(UdpHandle) tuck_sock = tuck_openUdp(port);
    if ((tuck_sock.status == rt.TuckStatus.Ok)) {
        scope(exit) {
            rt.finishResource(tuckRes_udp, tuck_sock.value);
        }
        return 1L;
    }
    return 0L;
}

long tuck_main() {
    return tuck_withScratch(16L);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_main();
    tuckResourcesShutdown();
    return cast(int) mainRc;
}
