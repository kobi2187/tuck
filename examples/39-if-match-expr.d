module _39_if_match_expr;

import rt = tuck_rt;
import sys = mod_sys;

enum tuck_Color { Red, Green, Blue }

void tuck_main() {
    bool tuck_hot = true;
    long tuck_limit = (tuck_hot ? 90 : 20);
    tuck_Color tuck_c = tuck_Color.Green;
    long tuck_code = (() { final switch (tuck_c) {
    case tuck_Color.Red: return 1;
    case tuck_Color.Green: return 2;
    case tuck_Color.Blue: return 3;
    } })();
    long tuck_name = (() { final switch (tuck_c) {
    case tuck_Color.Red: return 10;
    case tuck_Color.Green: return 20;
    case tuck_Color.Blue: return 30;
    } })();
    long tuck_scaled = (() { final switch (tuck_c) {
    case tuck_Color.Red: return (tuck_hot ? 100 : 1);
    case tuck_Color.Green: return (tuck_hot ? 200 : 2);
    case tuck_Color.Blue: return (tuck_hot ? 300 : 3);
    } })();
    if ((tuck_limit == 90)) {
        if ((tuck_code == 2)) {
            if ((tuck_name == 20)) {
                if ((tuck_scaled == 200)) {
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
