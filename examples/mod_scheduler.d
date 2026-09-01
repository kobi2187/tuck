module mod_scheduler;

import rt = tuck_rt;

alias tuck_Predicate = bool function();

void waitUntil(tuck_Predicate pred) {
    rt.waitUntil(pred);
}

void stop() {
    rt.stop();
}


