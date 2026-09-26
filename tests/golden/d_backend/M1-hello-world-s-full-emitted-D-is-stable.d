module t;

import rt = tuck_rt;
import console = mod_console;

long tuck_fn_main() {
    console.printLine("hello from tuck");
    return 7L;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_fn_main();
    return cast(int) mainRc;
}
