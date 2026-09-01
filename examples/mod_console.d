module mod_console;

import rt = tuck_rt;

struct TRec_console_line_5524 {
    string line;
}

enum tuck_IoError { EndOfInput, IoFailed }

void print(string text) {
    rt.print(text);
}

void printLine(string text) {
    rt.printLine(text);
}

rt.TuckResult!(TRec_console_line_5524) readLine() {
    return rt.readLine!(rt.TuckResult!(TRec_console_line_5524))();
}


