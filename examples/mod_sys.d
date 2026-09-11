module mod_sys;

import rt = tuck_rt;

struct TRec_sys_count(T_count) {
    T_count count;
}

struct TRec_sys_arg(T_arg) {
    T_arg arg;
}

struct TRec_sys_value(T_value) {
    T_value value;
}

TRec_sys_count!(long) argCount() {
    return rt.argCount!(TRec_sys_count!(long))();
}

TRec_sys_arg!(string) argAt(long index) {
    return rt.argAt!(TRec_sys_arg!(string))(index);
}

rt.TuckResult!(TRec_sys_value!(string)) getEnv(string name) {
    return rt.getEnv!(rt.TuckResult!(TRec_sys_value!(string)))(name);
}

void exit(long code) {
    rt.exit(code);
}


