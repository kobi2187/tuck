module mod_console;

import rt = tuck_rt;

struct TRec_console_line(T_line) {
    T_line line;
}

enum tuck_type_IoError { EndOfInput, IoFailed }

void print(string text) {
    rt.print(text);
}

void printLine(string text) {
    rt.printLine(text);
}

rt.TuckResult!(TRec_console_line!(string)) readLine() {
    return rt.readLine!(rt.TuckResult!(TRec_console_line!(string)))();
}


