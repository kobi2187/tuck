module mod_sys;

import rt = tuck_rt;
import tuckˑmodˑshapes_43_literal_payload = mod_shapes_43_literal_payload;

tuckˑmodˑshapes_43_literal_payload.TRec_count!(long) argCount() {
    return rt.argCount!(tuckˑmodˑshapes_43_literal_payload.TRec_count!(long))();
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


