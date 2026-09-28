module t;

import rt = tuck_rt;
import console = mod_console;

long tuckˑfnˑmain() {
    console.printLine("hello from tuck");
    return 7L;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuckˑfnˑmain();
    return cast(int) mainRc;
}
