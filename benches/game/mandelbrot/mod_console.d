module mod_console;

import rt = tuck_rt;
import tuckˑmodˑshapes_mandelbrot = mod_shapes_mandelbrot;

enum tuckˑtypeˑIoError { EndOfInput, IoFailed }

void print(string text) {
    rt.print(text);
}

void printLine(string text) {
    rt.printLine(text);
}

void printError(string text) {
    rt.printError(text);
}

rt.TuckResult!(tuckˑmodˑshapes_mandelbrot.TRec_line!(string)) readLine() {
    return rt.readLine!(rt.TuckResult!(tuckˑmodˑshapes_mandelbrot.TRec_line!(string)))();
}


