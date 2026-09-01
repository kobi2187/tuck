module _24_stdlib;

import rt = tuck_rt;
import fs = mod_fs;
import console = mod_console;

void tuck_main() {
    rt.TuckResult!(rt.TuckUnit) w = fs.writeFile("/tmp/tuck-demo.txt", "hello from tuck");
    if ((w.status == rt.TuckStatus.Ok)) {
        rt.TuckResult!(fs.TRec_fs_content_2C8C) r = fs.readFile("/tmp/tuck-demo.txt");
        if ((r.status == rt.TuckStatus.Ok)) {
            console.printLine(r.value.content);
            return;
        }
    }
    console.printLine("stdlib demo failed");
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
