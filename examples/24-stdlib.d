module _24_stdlib;

import rt = tuck_rt;
import tuckˑmodˑconsole = mod_console;
import tuckˑmodˑfs = mod_fs;

void tuckˑfnˑmain() {
    rt.TuckResult!(rt.TuckUnit) tuckˑvˑw = tuckˑmodˑfs.writeFile("/tmp/tuck-demo.txt", "hello from tuck");
    if ((tuckˑvˑw.status == rt.TuckStatus.Ok)) {
        rt.TuckResult!(tuckˑmodˑfs.TRec_fs_content!(string)) tuckˑvˑr = tuckˑmodˑfs.readFile("/tmp/tuck-demo.txt");
        scope(exit) rt.tuckDrop(tuckˑvˑr);
        if ((tuckˑvˑr.status == rt.TuckStatus.Ok)) {
            tuckˑmodˑconsole.printLine(tuckˑvˑr.value.content);
            return;
        }
    }
    tuckˑmodˑconsole.printLine("stdlib demo failed");
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckLeakMark();
    tuckˑfnˑmain();
    return rt.tuckLeakCheck(0);
}
