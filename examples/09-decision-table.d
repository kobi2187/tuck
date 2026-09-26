module _09_decision_table;

import rt = tuck_rt;

enum tuckˑtypeˑPriority { high, low }

enum tuckˑtypeˑSizeClass { big, small }

enum tuckˑtypeˑAction { QueueSecure, QueueFast, QueueImmediate, QueueDefer }

tuckˑtypeˑAction tuckˑdecisionˑclassifyPacket(tuckˑtypeˑPriority priority, tuckˑtypeˑSizeClass size, bool encrypted) {
    switch ((((cast(long)(priority) * 4L) + (cast(long)(size) * 2L)) + cast(long)(encrypted))) {
    case 0:
        return tuckˑtypeˑAction.QueueFast;
    case 1:
        return tuckˑtypeˑAction.QueueSecure;
    case 2, 3:
        return tuckˑtypeˑAction.QueueImmediate;
    default:
        return tuckˑtypeˑAction.QueueDefer;
    }
    return typeof(return).init;
}

