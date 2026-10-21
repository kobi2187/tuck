module mod_sys;

import rt = tuck_rt;
import tuckˑmodˑshapes_43_literal_payload = mod_shapes_43_literal_payload;

tuckˑmodˑshapes_43_literal_payload.TRec_total!(long) argCount() {
    return rt.argCount!(tuckˑmodˑshapes_43_literal_payload.TRec_total!(long))();
}

tuckˑmodˑshapes_43_literal_payload.TRec_arg!(string) argAt(long index) {
    return rt.argAt!(tuckˑmodˑshapes_43_literal_payload.TRec_arg!(string))(index);
}

rt.TuckResult!(tuckˑmodˑshapes_43_literal_payload.TRec_value!(string)) getEnv(string name) {
    return rt.getEnv!(rt.TuckResult!(tuckˑmodˑshapes_43_literal_payload.TRec_value!(string)))(name);
}

void exit(long code) {
    rt.exit(code);
}

long runCommand(string line) {
    return rt.runCommand(line);
}

void watchSignal(long number) {
    rt.watchSignal(number);
}

rt.TuckResult!(tuckˑmodˑshapes_43_literal_payload.TRec_number!(long)) nextSignal(long timeoutMs) {
    return rt.nextSignal!(rt.TuckResult!(tuckˑmodˑshapes_43_literal_payload.TRec_number!(long)))(timeoutMs);
}

void raiseSignal(long number) {
    rt.raiseSignal(number);
}


