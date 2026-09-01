module _21_decision_bitmask;

import rt = tuck_rt;

enum tuck_Priority { High, Low }

long tuck_route(tuck_Priority priority, bool encrypted) {
    switch (cast(long)(priority) * 2 + cast(long)(encrypted)) {   // packed decision key
    case 0:
        return 2;
    case 1:
        return 1;
    default: return 3;
    }
}

