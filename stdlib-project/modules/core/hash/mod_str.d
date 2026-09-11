module mod_str;

import rt = tuck_rt;

string toStr(T)(T value) {
    return rt.toStr(value);
}

string charAt(string s, long index) {
    return rt.charAt(s, index);
}

bool containsChar(string s, string ch) {
    return rt.containsChar(s, ch);
}

string[] splitLines(string s) {
    return rt.splitLines(s);
}

long ord(string ch) {
    return rt.ord(ch);
}


