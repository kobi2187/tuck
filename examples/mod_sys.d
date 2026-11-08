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

tuckˑmodˑshapes_43_literal_payload.TRec_code_output!(long, string) captureCommand(string line) {
    return rt.captureCommand!(tuckˑmodˑshapes_43_literal_payload.TRec_code_output!(long, string))(line);
}

tuckˑmodˑshapes_43_literal_payload.TRec_code!(long) setEnv(string name, string value) {
    return rt.setEnv!(tuckˑmodˑshapes_43_literal_payload.TRec_code!(long))(name, value);
}

tuckˑmodˑshapes_43_literal_payload.TRec_code!(long) unsetEnv(string name) {
    return rt.unsetEnv!(tuckˑmodˑshapes_43_literal_payload.TRec_code!(long))(name);
}

tuckˑmodˑshapes_43_literal_payload.TRec_path!(string) currentDir() {
    return rt.currentDir!(tuckˑmodˑshapes_43_literal_payload.TRec_path!(string))();
}

tuckˑmodˑshapes_43_literal_payload.TRec_code!(long) changeDir(string path) {
    return rt.changeDir!(tuckˑmodˑshapes_43_literal_payload.TRec_code!(long))(path);
}

tuckˑmodˑshapes_43_literal_payload.TRec_path!(string) exePath() {
    return rt.exePath!(tuckˑmodˑshapes_43_literal_payload.TRec_path!(string))();
}

tuckˑmodˑshapes_43_literal_payload.TRec_pid_input_output_errors!(long, long, long, long) spawnProcess(string argv) {
    return rt.spawnProcess!(tuckˑmodˑshapes_43_literal_payload.TRec_pid_input_output_errors!(long, long, long, long))(argv);
}

tuckˑmodˑshapes_43_literal_payload.TRec_data!(string) fdRead(long fd, long max) {
    return rt.fdRead!(tuckˑmodˑshapes_43_literal_payload.TRec_data!(string))(fd, max);
}

rt.TuckResult!(tuckˑmodˑshapes_43_literal_payload.TRec_data!(string)) fdReadWithin(long fd, long max, long timeoutMs) {
    return rt.fdReadWithin!(rt.TuckResult!(tuckˑmodˑshapes_43_literal_payload.TRec_data!(string)))(fd, max, timeoutMs);
}

tuckˑmodˑshapes_43_literal_payload.TRec_sent!(long) fdWrite(long fd, string data) {
    return rt.fdWrite!(tuckˑmodˑshapes_43_literal_payload.TRec_sent!(long))(fd, data);
}

void fdClose(long fd) {
    rt.fdClose(fd);
}

tuckˑmodˑshapes_43_literal_payload.TRec_code!(long) waitProcess(long pid) {
    return rt.waitProcess!(tuckˑmodˑshapes_43_literal_payload.TRec_code!(long))(pid);
}

rt.TuckResult!(tuckˑmodˑshapes_43_literal_payload.TRec_code!(long)) pollProcess(long pid) {
    return rt.pollProcess!(rt.TuckResult!(tuckˑmodˑshapes_43_literal_payload.TRec_code!(long)))(pid);
}

tuckˑmodˑshapes_43_literal_payload.TRec_code!(long) killProcess(long pid, long sig) {
    return rt.killProcess!(tuckˑmodˑshapes_43_literal_payload.TRec_code!(long))(pid, sig);
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


