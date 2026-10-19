module mod_console;

import rt = tuck_rt;
import tuckˑmodˑshapes_41_tostr_concat = mod_shapes_41_tostr_concat;

enum tuckˑtypeˑIoError { EndOfInput, IoFailed }

void print(string text) {
    rt.print(text);
}

void printLine(string text) {
    rt.printLine(text);
}

rt.TuckResult!(tuckˑmodˑshapes_41_tostr_concat.TRec_line!(string)) readLine() {
    return rt.readLine!(rt.TuckResult!(tuckˑmodˑshapes_41_tostr_concat.TRec_line!(string)))();
}


