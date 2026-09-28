module mod_scheduler;

import rt = tuck_rt;

alias tuckˑfnsigˑPredicate = bool function();

void runTasksUntil(tuckˑfnsigˑPredicate pred) {
    rt.runTasksUntil(pred);
}

void stop() {
    rt.stop();
}


