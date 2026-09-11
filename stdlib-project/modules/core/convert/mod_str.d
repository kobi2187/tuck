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

string joinStr(string[] parts, string sep) {
    return rt.joinStr(parts, sep);
}

ubyte byteAt(string t, long index) {
    return rt.byteAt(t, index);
}

long byteCount(string t) {
    return rt.byteCount(t);
}

rt.TuckResult!(double) parseFloat(string t) {
    return rt.parseFloat(t);
}

string fromBytes(ubyte[] bytes) {
    return rt.fromBytes(bytes);
}


