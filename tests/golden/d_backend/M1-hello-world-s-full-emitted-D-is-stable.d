module t;

import rt = tuck_rt;
import console = mod_console;

long tuck_main() {
    console.printLine("hello from tuck");
    return 7;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_main();
    return cast(int) mainRc;
}
