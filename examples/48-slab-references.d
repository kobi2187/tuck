module _48_slab_references;

import rt = tuck_rt;

struct tuckˑtypeˑNode {
    long data;
    rt.TuckResult!(rt.SlabRef) prev;
    rt.TuckResult!(rt.SlabRef) next;
}

__gshared rt.SlabChunked!(tuckˑtypeˑNode) tuckˑslabˑNodes = rt.SlabChunked!(tuckˑtypeˑNode)("Nodes");

rt.SlabRef tuckˑfnˑemptyList() {
    rt.SlabRef tuckˑvˑs = rt.tuckSlabNew(tuckˑslabˑNodes, tuckˑtypeˑNode(data: 0L, prev: rt.tnone!(rt.SlabRef)(), next: rt.tnone!(rt.SlabRef)()));
    rt.tuckSlabCell(tuckˑslabˑNodes, tuckˑvˑs).value.prev = rt.tok!(rt.SlabRef)(tuckˑvˑs);
    rt.tuckSlabCell(tuckˑslabˑNodes, tuckˑvˑs).value.next = rt.tok!(rt.SlabRef)(tuckˑvˑs);
    return tuckˑvˑs;
}

rt.SlabRef tuckˑfnˑafter(rt.SlabRef n) {
    rt.TuckResult!(rt.SlabRef) tuckˑvˑx = rt.tuckSlabCell(tuckˑslabˑNodes, n).value.next;
    if ((tuckˑvˑx.status == rt.TuckStatus.Ok)) {
        return tuckˑvˑx.value;
    }
    return n;
}

rt.SlabRef tuckˑfnˑbefore(rt.SlabRef n) {
    rt.TuckResult!(rt.SlabRef) tuckˑvˑx = rt.tuckSlabCell(tuckˑslabˑNodes, n).value.prev;
    if ((tuckˑvˑx.status == rt.TuckStatus.Ok)) {
        return tuckˑvˑx.value;
    }
    return n;
}

rt.SlabRef tuckˑfnˑpushBack(rt.SlabRef list, long data) {
    rt.SlabRef tuckˑvˑlast = tuckˑfnˑbefore(list);
    rt.SlabRef tuckˑvˑn = rt.tuckSlabNew(tuckˑslabˑNodes, tuckˑtypeˑNode(data: data, prev: rt.tok!(rt.SlabRef)(tuckˑvˑlast), next: rt.tok!(rt.SlabRef)(list)));
    rt.tuckSlabCell(tuckˑslabˑNodes, tuckˑvˑlast).value.next = rt.tok!(rt.SlabRef)(tuckˑvˑn);
    rt.tuckSlabCell(tuckˑslabˑNodes, list).value.prev = rt.tok!(rt.SlabRef)(tuckˑvˑn);
    return tuckˑvˑn;
}

void tuckˑfnˑremove(rt.SlabRef n) {
    rt.SlabRef tuckˑvˑp = tuckˑfnˑbefore(n);
    rt.SlabRef tuckˑvˑq = tuckˑfnˑafter(n);
    rt.tuckSlabCell(tuckˑslabˑNodes, tuckˑvˑp).value.next = rt.tok!(rt.SlabRef)(tuckˑvˑq);
    rt.tuckSlabCell(tuckˑslabˑNodes, tuckˑvˑq).value.prev = rt.tok!(rt.SlabRef)(tuckˑvˑp);
    rt.tuckSlabFree(tuckˑslabˑNodes, n);
}

long tuckˑfnˑsumForward(rt.SlabRef list) {
    long tuckˑvˑtotal = 0L;
    rt.SlabRef tuckˑvˑcur = tuckˑfnˑafter(list);
    while ((tuckˑvˑcur != list)) {
        tuckˑvˑtotal = (tuckˑvˑtotal + rt.tuckSlabCell(tuckˑslabˑNodes, tuckˑvˑcur).value.data);
        tuckˑvˑcur = tuckˑfnˑafter(tuckˑvˑcur);
    }
    return tuckˑvˑtotal;
}

long tuckˑfnˑsumBackward(rt.SlabRef list) {
    long tuckˑvˑtotal = 0L;
    rt.SlabRef tuckˑvˑcur = tuckˑfnˑbefore(list);
    while ((tuckˑvˑcur != list)) {
        tuckˑvˑtotal = (tuckˑvˑtotal + rt.tuckSlabCell(tuckˑslabˑNodes, tuckˑvˑcur).value.data);
        tuckˑvˑcur = tuckˑfnˑbefore(tuckˑvˑcur);
    }
    return tuckˑvˑtotal;
}

struct tuckˑtypeˑDir {
    long bytes;
    rt.TuckResult!(rt.SlabRef) parent;
}

__gshared rt.SlabChunked!(tuckˑtypeˑDir) tuckˑslabˑDirs = rt.SlabChunked!(tuckˑtypeˑDir)("Dirs");

void tuckˑfnˑaddFile(rt.SlabRef dir, long bytes) {
    rt.tuckSlabCell(tuckˑslabˑDirs, dir).value.bytes = (rt.tuckSlabCell(tuckˑslabˑDirs, dir).value.bytes + bytes);
    rt.TuckResult!(rt.SlabRef) tuckˑvˑup = rt.tuckSlabCell(tuckˑslabˑDirs, dir).value.parent;
    if ((tuckˑvˑup.status == rt.TuckStatus.Ok)) {
        tuckˑfnˑaddFile(tuckˑvˑup.value, bytes);
    }
}

long tuckˑfnˑdepth(rt.SlabRef dir) {
    rt.TuckResult!(rt.SlabRef) tuckˑvˑup = rt.tuckSlabCell(tuckˑslabˑDirs, dir).value.parent;
    if (!(tuckˑvˑup.status == rt.TuckStatus.Ok)) {
        return 0L;
    }
    return (1L + tuckˑfnˑdepth(tuckˑvˑup.value));
}

struct tuckˑtypeˑStop {
    long minutes;
    rt.TuckResult!(rt.SlabRef) next;
}

__gshared rt.SlabChunked!(tuckˑtypeˑStop) tuckˑslabˑStops = rt.SlabChunked!(tuckˑtypeˑStop)("Stops");

long tuckˑfnˑlapFrom(rt.SlabRef at, rt.SlabRef start) {
    if ((at == start)) {
        return 0L;
    }
    rt.TuckResult!(rt.SlabRef) tuckˑvˑnext = rt.tuckSlabCell(tuckˑslabˑStops, at).value.next;
    if (!(tuckˑvˑnext.status == rt.TuckStatus.Ok)) {
        return rt.tuckSlabCell(tuckˑslabˑStops, at).value.minutes;
    }
    return (rt.tuckSlabCell(tuckˑslabˑStops, at).value.minutes + tuckˑfnˑlapFrom(tuckˑvˑnext.value, start));
}

long tuckˑfnˑlapMinutes(rt.SlabRef start) {
    rt.TuckResult!(rt.SlabRef) tuckˑvˑnext = rt.tuckSlabCell(tuckˑslabˑStops, start).value.next;
    if (!(tuckˑvˑnext.status == rt.TuckStatus.Ok)) {
        return rt.tuckSlabCell(tuckˑslabˑStops, start).value.minutes;
    }
    return (rt.tuckSlabCell(tuckˑslabˑStops, start).value.minutes + tuckˑfnˑlapFrom(tuckˑvˑnext.value, start));
}

long tuckˑfnˑmain() {
    rt.SlabRef tuckˑvˑlist = tuckˑfnˑemptyList();
    rt.SlabRef tuckˑvˑa = tuckˑfnˑpushBack(tuckˑvˑlist, 10L);
    rt.SlabRef tuckˑvˑb = tuckˑfnˑpushBack(tuckˑvˑlist, 20L);
    rt.SlabRef tuckˑvˑc = tuckˑfnˑpushBack(tuckˑvˑlist, 30L);
    rt.SlabRef tuckˑvˑd = tuckˑfnˑpushBack(tuckˑvˑlist, 40L);
    tuckˑfnˑremove(tuckˑvˑb);
    if ((tuckˑfnˑsumForward(tuckˑvˑlist) != 80L)) {
        return 1L;
    }
    if ((tuckˑfnˑsumBackward(tuckˑvˑlist) != 80L)) {
        return 2L;
    }
    if (rt.tuckSlabLive(tuckˑslabˑNodes, tuckˑvˑb)) {
        return 3L;
    }
    if (!rt.tuckSlabLive(tuckˑslabˑNodes, tuckˑvˑc)) {
        return 4L;
    }
    rt.SlabRef tuckˑvˑroot = rt.tuckSlabNew(tuckˑslabˑDirs, tuckˑtypeˑDir(bytes: 0L, parent: rt.tnone!(rt.SlabRef)()));
    rt.SlabRef tuckˑvˑsrc = rt.tuckSlabNew(tuckˑslabˑDirs, tuckˑtypeˑDir(bytes: 0L, parent: rt.tok!(rt.SlabRef)(tuckˑvˑroot)));
    rt.SlabRef tuckˑvˑlib = rt.tuckSlabNew(tuckˑslabˑDirs, tuckˑtypeˑDir(bytes: 0L, parent: rt.tok!(rt.SlabRef)(tuckˑvˑsrc)));
    tuckˑfnˑaddFile(tuckˑvˑlib, 3L);
    tuckˑfnˑaddFile(tuckˑvˑlib, 4L);
    if (((rt.tuckSlabCell(tuckˑslabˑDirs, tuckˑvˑroot).value.bytes != 7L) || ((rt.tuckSlabCell(tuckˑslabˑDirs, tuckˑvˑsrc).value.bytes != 7L) || (rt.tuckSlabCell(tuckˑslabˑDirs, tuckˑvˑlib).value.bytes != 7L)))) {
        return 5L;
    }
    if ((tuckˑfnˑdepth(tuckˑvˑlib) != 2L)) {
        return 6L;
    }
    rt.SlabRef tuckˑvˑs1 = rt.tuckSlabNew(tuckˑslabˑStops, tuckˑtypeˑStop(minutes: 5L, next: rt.tnone!(rt.SlabRef)()));
    rt.SlabRef tuckˑvˑs2 = rt.tuckSlabNew(tuckˑslabˑStops, tuckˑtypeˑStop(minutes: 7L, next: rt.tok!(rt.SlabRef)(tuckˑvˑs1)));
    rt.SlabRef tuckˑvˑs3 = rt.tuckSlabNew(tuckˑslabˑStops, tuckˑtypeˑStop(minutes: 9L, next: rt.tok!(rt.SlabRef)(tuckˑvˑs2)));
    rt.tuckSlabCell(tuckˑslabˑStops, tuckˑvˑs1).value.next = rt.tok!(rt.SlabRef)(tuckˑvˑs3);
    if ((tuckˑfnˑlapMinutes(tuckˑvˑs1) != 21L)) {
        return 7L;
    }
    rt.tuckSlabReset(tuckˑslabˑStops);
    if (rt.tuckSlabLive(tuckˑslabˑStops, tuckˑvˑs1)) {
        return 8L;
    }
    rt.tuckSlabReset(tuckˑslabˑNodes);
    if ((rt.tuckSlabLive(tuckˑslabˑNodes, tuckˑvˑa) || rt.tuckSlabLive(tuckˑslabˑNodes, tuckˑvˑd))) {
        return 9L;
    }
    return 0L;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuckˑfnˑmain();
    rt.tuckSlabReport(tuckˑslabˑNodes);
    rt.tuckSlabReport(tuckˑslabˑStops);
    return cast(int) mainRc;
}
