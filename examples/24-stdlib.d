module _24_stdlib;

import rt = tuck_rt;
import fs = mod_fs;
import console = mod_console;

void tuckˑfnˑmain() {
    rt.TuckResult!(rt.TuckUnit) tuckˑvˑw = fs.writeFile("/tmp/tuck-demo.txt", "hello from tuck");
    if ((tuckˑvˑw.status == rt.TuckStatus.Ok)) {
        rt.TuckResult!(fs.TRec_fs_content!(string)) tuckˑvˑr = fs.readFile("/tmp/tuck-demo.txt");
        if ((tuckˑvˑr.status == rt.TuckStatus.Ok)) {
            console.printLine(tuckˑvˑr.value.content);
            return;
        }
    }
    console.printLine("stdlib demo failed");
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuckˑfnˑmain();
}
