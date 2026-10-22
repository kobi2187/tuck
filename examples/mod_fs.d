module mod_fs;

import rt = tuck_rt;
import tuckˑmodˑshapes_24_stdlib = mod_shapes_24_stdlib;

enum tuckˑtypeˑFsError { NotFound, AccessDenied, IoFailed, NotEmpty }

rt.TuckResult!(tuckˑmodˑshapes_24_stdlib.TRec_content!(string)) readFile(string path) {
    return rt.readFile!(rt.TuckResult!(tuckˑmodˑshapes_24_stdlib.TRec_content!(string)))(path);
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

string[] listDir(string path) {
    return rt.listDir(path);
}

rt.TuckResult!(tuckˑmodˑshapes_24_stdlib.TRec_isFolder_isLink_bytes_modifiedMs!(bool, bool, long, long)) pathInfo(string path) {
    return rt.pathInfo!(rt.TuckResult!(tuckˑmodˑshapes_24_stdlib.TRec_isFolder_isLink_bytes_modifiedMs!(bool, bool, long, long)))(path);
}

rt.TuckResult!(rt.TuckUnit) renamePath(string path, string to) {
    return rt.renamePath(path, to);
}

rt.TuckResult!(rt.TuckUnit) removeFolder(string path) {
    return rt.removeFolder(path);
}


