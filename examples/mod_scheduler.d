module mod_scheduler;

import rt = tuck_rt;

alias tuck_type_Predicate = bool function();

void runTasksUntil(tuck_type_Predicate pred) {
    rt.runTasksUntil(pred);
}

void stop() {
    rt.stop();
}


