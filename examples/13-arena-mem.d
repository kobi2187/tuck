module _13_arena_mem;

import rt = tuck_rt;

struct tuckˑtypeˑEthernetFrame {
    long len;
    ubyte[128] bytes;
}

struct tuckˑtypeˑHeader {
    long len;
    rt.SlabRef frame;
}

__gshared rt.ArenaBudget tuckˑarenaˑScratchSpace = rt.ArenaBudget(2048, 0);
void tuckˑarenaˑScratchSpace_reset()
{
    rt.tuckSlabReset(tuckˑslabˑScratchSpace_EthernetFrame);
    rt.tuckSlabReset(tuckˑslabˑScratchSpace_Header);
    tuckˑarenaˑScratchSpace.used = 0;
}

__gshared rt.SlabChunked!(tuckˑtypeˑEthernetFrame) tuckˑslabˑScratchSpace_EthernetFrame = rt.SlabChunked!(tuckˑtypeˑEthernetFrame)("ScratchSpace");

__gshared rt.SlabChunked!(tuckˑtypeˑHeader) tuckˑslabˑScratchSpace_Header = rt.SlabChunked!(tuckˑtypeˑHeader)("ScratchSpace");

long tuckˑfnˑhandle(long len) {
    ubyte[128] tuckˑvˑraw = rt.tuckFill!(ubyte, 128L)(cast(ubyte)(0L));
    tuckˑtypeˑEthernetFrame tuckˑvˑf = tuckˑtypeˑEthernetFrame(len: len, bytes: tuckˑvˑraw);
    rt.TuckResult!(rt.SlabRef) tuckˑvˑfr = rt.tuckArenaNew(tuckˑslabˑScratchSpace_EthernetFrame, tuckˑarenaˑScratchSpace, 144, tuckˑvˑf);
    if (!(tuckˑvˑfr.status == rt.TuckStatus.Ok)) {
        return 0L;
    }
    tuckˑtypeˑHeader tuckˑvˑh = tuckˑtypeˑHeader(len: len, frame: tuckˑvˑfr.value);
    rt.TuckResult!(rt.SlabRef) tuckˑvˑhr = rt.tuckArenaNew(tuckˑslabˑScratchSpace_Header, tuckˑarenaˑScratchSpace, 24, tuckˑvˑh);
    if (!(tuckˑvˑhr.status == rt.TuckStatus.Ok)) {
        return 0L;
    }
    rt.tuckSlabCell(tuckˑslabˑScratchSpace_EthernetFrame, rt.tuckSlabCell(tuckˑslabˑScratchSpace_Header, tuckˑvˑhr.value).value.frame).value.len = (rt.tuckSlabCell(tuckˑslabˑScratchSpace_EthernetFrame, rt.tuckSlabCell(tuckˑslabˑScratchSpace_Header, tuckˑvˑhr.value).value.frame).value.len + 1L);
    return rt.tuckSlabCell(tuckˑslabˑScratchSpace_EthernetFrame, rt.tuckSlabCell(tuckˑslabˑScratchSpace_Header, tuckˑvˑhr.value).value.frame).value.len;
}

long tuckˑfnˑmain() {
    long tuckˑvˑhandled = 0L;
    long tuckˑvˑi = 0L;
    while ((tuckˑvˑi < 5L)) {
        tuckˑvˑhandled = (tuckˑvˑhandled + tuckˑfnˑhandle(10L));
        tuckˑvˑi = (tuckˑvˑi + 1L);
    }
    tuckˑarenaˑScratchSpace_reset();
    return tuckˑvˑhandled;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuckˑfnˑmain();
    return cast(int) mainRc;
}
