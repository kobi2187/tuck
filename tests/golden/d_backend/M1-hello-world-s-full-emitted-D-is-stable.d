module t;

import rt = tuck_rt;
import tuckˑmodˑconsole = mod_console;

long tuckˑfnˑmain() {
    tuckˑmodˑconsole.printLine("hello from tuck");
    return 7L;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckLeakMark();
    auto mainRc = tuckˑfnˑmain();
    return rt.tuckLeakCheck(cast(int) mainRc);
}
