module _39_if_match_expr;

import rt = tuck_rt;
import sys = mod_sys;

enum tuck_type_Color { Red, Green, Blue }

void tuck_fn_main() {
    bool tuck_hot = true;
    long tuck_limit = (tuck_hot ? 90L : 20L);
    tuck_type_Color tuck_c = tuck_type_Color.Green;
    long tuck_code = (() { final switch (tuck_c) {
    case tuck_type_Color.Red: return 1L;
    case tuck_type_Color.Green: return 2L;
    case tuck_type_Color.Blue: return 3L;
    } })();
    long tuck_name = (() { final switch (tuck_c) {
    case tuck_type_Color.Red: return 10L;
    case tuck_type_Color.Green: return 20L;
    case tuck_type_Color.Blue: return 30L;
    } })();
    long tuck_scaled = (() { final switch (tuck_c) {
    case tuck_type_Color.Red: return (tuck_hot ? 100L : 1L);
    case tuck_type_Color.Green: return (tuck_hot ? 200L : 2L);
    case tuck_type_Color.Blue: return (tuck_hot ? 300L : 3L);
    } })();
    if ((tuck_limit == 90L)) {
        if ((tuck_code == 2L)) {
            if ((tuck_name == 20L)) {
                if ((tuck_scaled == 200L)) {
                    sys.exit(0L);
                }
            }
        }
    }
    sys.exit(1L);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_fn_main();
}
