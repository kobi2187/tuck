module _39_if_match_expr;

import rt = tuck_rt;
import sys = mod_sys;

enum tuck_Color { Red, Green, Blue }

void tuck_main() {
    bool hot = true;
    long limit = (hot ? 90 : 20);
    tuck_Color c = tuck_Color.Green;
    long code = (() { final switch (c) {
    case tuck_Color.Red: return 1;
    case tuck_Color.Green: return 2;
    case tuck_Color.Blue: return 3;
    } })();
    long name = (() { final switch (c) {
    case tuck_Color.Red: return 10;
    case tuck_Color.Green: return 20;
    case tuck_Color.Blue: return 30;
    } })();
    long scaled = (() { final switch (c) {
    case tuck_Color.Red: return (hot ? 100 : 1);
    case tuck_Color.Green: return (hot ? 200 : 2);
    case tuck_Color.Blue: return (hot ? 300 : 3);
    } })();
    if ((limit == 90)) {
        if ((code == 2)) {
            if ((name == 20)) {
                if ((scaled == 200)) {
                    sys.exit(0);
                }
            }
        }
    }
    sys.exit(1);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
