module _21_decision_bitmask;

import rt = tuck_rt;

enum tuckˑtypeˑPriority { High, Low }

long tuckˑdecisionˑroute(tuckˑtypeˑPriority priority, bool encrypted) {
    switch (((cast(long)(priority) * 2L) + cast(long)(encrypted))) {
    case 0:
        return 2L;
    case 1:
        return 1L;
    default:
        return 3L;
    }
    return typeof(return).init;
}

