module _09_decision_table;

import rt = tuck_rt;

enum tuck_Priority { high, low }

enum tuck_SizeClass { big, small }

enum tuck_Action { QueueSecure, QueueFast, QueueImmediate, QueueDefer }

tuck_Action tuck_classifyPacket(tuck_Priority priority, tuck_SizeClass size, bool encrypted) {
    switch (cast(long)(priority) * 4 + cast(long)(size) * 2 + cast(long)(encrypted)) {   // packed decision key
    case 0:
        return tuck_Action.QueueFast;
    case 1:
        return tuck_Action.QueueSecure;
    case 2:
    case 3:
        return tuck_Action.QueueImmediate;
    default: return tuck_Action.QueueDefer;
    }
}

