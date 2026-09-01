module mod_sys;

import rt = tuck_rt;

struct TRec_sys_count_66EB {
    long count;
}

struct TRec_sys_arg_C032 {
    string arg;
}

struct TRec_sys_value_E127 {
    string value;
}

TRec_sys_count_66EB argCount() {
    return rt.argCount!(TRec_sys_count_66EB)();
}

TRec_sys_arg_C032 argAt(long index) {
    return rt.argAt!(TRec_sys_arg_C032)(index);
}

rt.TuckResult!(TRec_sys_value_E127) getEnv(string name) {
    return rt.getEnv!(rt.TuckResult!(TRec_sys_value_E127))(name);
}

void exit(long code) {
    rt.exit(code);
}


