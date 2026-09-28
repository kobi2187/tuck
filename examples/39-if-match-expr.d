module _39_if_match_expr;

import rt = tuck_rt;
import sys = mod_sys;

enum tuckˑtypeˑColor { Red, Green, Blue }

void tuckˑfnˑmain() {
    bool tuckˑvˑhot = true;
    long tuckˑvˑlimit = (tuckˑvˑhot ? 90L : 20L);
    tuckˑtypeˑColor tuckˑvˑc = tuckˑtypeˑColor.Green;
    long tuckˑvˑcode = (() { final switch (tuckˑvˑc) {
    case tuckˑtypeˑColor.Red: return 1L;
    case tuckˑtypeˑColor.Green: return 2L;
    case tuckˑtypeˑColor.Blue: return 3L;
    } })();
    long tuckˑvˑname = (() { final switch (tuckˑvˑc) {
    case tuckˑtypeˑColor.Red: return 10L;
    case tuckˑtypeˑColor.Green: return 20L;
    case tuckˑtypeˑColor.Blue: return 30L;
    } })();
    long tuckˑvˑscaled = (() { final switch (tuckˑvˑc) {
    case tuckˑtypeˑColor.Red: return (tuckˑvˑhot ? 100L : 1L);
    case tuckˑtypeˑColor.Green: return (tuckˑvˑhot ? 200L : 2L);
    case tuckˑtypeˑColor.Blue: return (tuckˑvˑhot ? 300L : 3L);
    } })();
    if ((tuckˑvˑlimit == 90L)) {
        if ((tuckˑvˑcode == 2L)) {
            if ((tuckˑvˑname == 20L)) {
                if ((tuckˑvˑscaled == 200L)) {
                    sys.exit(0L);
                }
            }
        }
    }
    sys.exit(1L);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuckˑfnˑmain();
}
