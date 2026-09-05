module _24_stdlib;

import rt = tuck_rt;
import fs = mod_fs;
import console = mod_console;

void tuck_main() {
    rt.TuckResult!(rt.TuckUnit) tuck_w = fs.writeFile("/tmp/tuck-demo.txt", "hello from tuck");
    if ((tuck_w.status == rt.TuckStatus.Ok)) {
        rt.TuckResult!(fs.TRec_fs_content_2C8C) tuck_r = fs.readFile("/tmp/tuck-demo.txt");
        if ((tuck_r.status == rt.TuckStatus.Ok)) {
            console.printLine(tuck_r.value.content);
            return;
        }
    }
    console.printLine("stdlib demo failed");
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
