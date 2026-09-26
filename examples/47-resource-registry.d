module _47_resource_registry;

import rt = tuck_rt;
import std.stdio : writeln, stderr;

enum tuckˑtypeˑNetState { Connecting, Ready, Closed }

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

long tuckˑfnˑrawOpenUdp(T)(T payload) {
    stderr.writeln("TUCK PENDING: rawOpenUdp invoked (not implemented)");
    return typeof(return).init;
}


rt.TuckResult!(UdpHandle) tuckˑfnˑopenUdp(ushort port) {
    return rt.acquireResource(tuckRes_udp, cast(long)(tuckˑfnˑrawOpenUdp(port)), "47-resource-registry:73");
}

long tuckˑfnˑwithScratch(long n) {
    long tuckˑvˑscratch = n;
    scope(exit) {
        tuckˑvˑscratch = 0L;
    }
    return (tuckˑvˑscratch + 1L);
}

long tuckˑfnˑserve(ushort port) {
    rt.TuckResult!(UdpHandle) tuckˑvˑsock = tuckˑfnˑopenUdp(port);
    if ((tuckˑvˑsock.status == rt.TuckStatus.Ok)) {
        scope(exit) {
            rt.finishResource(tuckRes_udp, tuckˑvˑsock.value);
        }
        return 1L;
    }
    return 0L;
}

long tuckˑfnˑmain() {
    return tuckˑfnˑwithScratch(16L);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuckˑfnˑmain();
    tuckResourcesShutdown();
    return cast(int) mainRc;
}
