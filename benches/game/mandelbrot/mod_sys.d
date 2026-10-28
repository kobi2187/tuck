module mod_sys;

import rt = tuck_rt;
import tuckˑmodˑshapes_mandelbrot = mod_shapes_mandelbrot;

tuckˑmodˑshapes_mandelbrot.TRec_total!(long) argCount() {
    return rt.argCount!(tuckˑmodˑshapes_mandelbrot.TRec_total!(long))();
}

tuckˑmodˑshapes_mandelbrot.TRec_arg!(string) argAt(long index) {
    return rt.argAt!(tuckˑmodˑshapes_mandelbrot.TRec_arg!(string))(index);
}

rt.TuckResult!(tuckˑmodˑshapes_mandelbrot.TRec_value!(string)) getEnv(string name) {
    return rt.getEnv!(rt.TuckResult!(tuckˑmodˑshapes_mandelbrot.TRec_value!(string)))(name);
}

void exit(long code) {
    rt.exit(code);
}

long runCommand(string line) {
    return rt.runCommand(line);
}

tuckˑmodˑshapes_mandelbrot.TRec_code_output!(long, string) captureCommand(string line) {
    return rt.captureCommand!(tuckˑmodˑshapes_mandelbrot.TRec_code_output!(long, string))(line);
}

void watchSignal(long number) {
    rt.watchSignal(number);
}

rt.TuckResult!(tuckˑmodˑshapes_mandelbrot.TRec_number!(long)) nextSignal(long timeoutMs) {
    return rt.nextSignal!(rt.TuckResult!(tuckˑmodˑshapes_mandelbrot.TRec_number!(long)))(timeoutMs);
}

void raiseSignal(long number) {
    rt.raiseSignal(number);
}


