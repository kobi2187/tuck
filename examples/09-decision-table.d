module _09_decision_table;

import rt = tuck_rt;

enum tuck_type_Priority { high, low }

enum tuck_type_SizeClass { big, small }

enum tuck_type_Action { QueueSecure, QueueFast, QueueImmediate, QueueDefer }

tuck_type_Action tuck_fn_classifyPacket(tuck_type_Priority priority, tuck_type_SizeClass size, bool encrypted) {
    switch ((((cast(long)(priority) * 4L) + (cast(long)(size) * 2L)) + cast(long)(encrypted))) {
    case 0:
        return tuck_type_Action.QueueFast;
    case 1:
        return tuck_type_Action.QueueSecure;
    case 2, 3:
        return tuck_type_Action.QueueImmediate;
    default:
        return tuck_type_Action.QueueDefer;
    }
    return typeof(return).init;
}

