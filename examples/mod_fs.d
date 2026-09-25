module mod_fs;

import rt = tuck_rt;

struct TRec_fs_content(T_content) {
    T_content content;
}

enum tuck_type_FsError { NotFound, AccessDenied, IoFailed }

rt.TuckResult!(TRec_fs_content!(string)) readFile(string path) {
    return rt.readFile!(rt.TuckResult!(TRec_fs_content!(string)))(path);
}

rt.TuckResult!(rt.TuckUnit) writeFile(string path, string content) {
    return rt.writeFile(path, content);
}

rt.TuckResult!(rt.TuckUnit) appendFile(string path, string content) {
    return rt.appendFile(path, content);
}

bool fileExists(string path) {
    return rt.fileExists(path);
}

rt.TuckResult!(rt.TuckUnit) removeFile(string path) {
    return rt.removeFile(path);
}

rt.TuckResult!(rt.TuckUnit) makeDir(string path) {
    return rt.makeDir(path);
}


