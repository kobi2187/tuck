module mod_fs;

import rt = tuck_rt;

struct TRec_fs_content_2C8C {
    string content;
}

enum tuck_FsError { NotFound, AccessDenied, IoFailed }

rt.TuckResult!(TRec_fs_content_2C8C) readFile(string path) {
    return rt.readFile!(rt.TuckResult!(TRec_fs_content_2C8C))(path);
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


