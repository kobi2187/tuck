module mod_net;

import rt = tuck_rt;
import tuckˑmodˑshapes_42_net_echo = mod_shapes_42_net_echo;

enum tuckˑtypeˑNetError { Refused, AddressInUse, Unreachable, Closed, IoFailed }

rt.TuckResult!(tuckˑmodˑshapes_42_net_echo.TRec_fd!(long)) listen(long port) {
    return rt.listen!(rt.TuckResult!(tuckˑmodˑshapes_42_net_echo.TRec_fd!(long)))(port);
}

rt.TuckResult!(tuckˑmodˑshapes_42_net_echo.TRec_fd!(long)) accept(long fd) {
    return rt.accept!(rt.TuckResult!(tuckˑmodˑshapes_42_net_echo.TRec_fd!(long)))(fd);
}

rt.TuckResult!(tuckˑmodˑshapes_42_net_echo.TRec_fd!(long)) connect(string host, long port) {
    return rt.connect!(rt.TuckResult!(tuckˑmodˑshapes_42_net_echo.TRec_fd!(long)))(host, port);
}

rt.TuckResult!(tuckˑmodˑshapes_42_net_echo.TRec_data!(string)) recv(long fd, long max) {
    return rt.recv!(rt.TuckResult!(tuckˑmodˑshapes_42_net_echo.TRec_data!(string)))(fd, max);
}

rt.TuckResult!(tuckˑmodˑshapes_42_net_echo.TRec_sent!(long)) send(long fd, string data) {
    return rt.send!(rt.TuckResult!(tuckˑmodˑshapes_42_net_echo.TRec_sent!(long)))(fd, data);
}

void close(long fd) {
    rt.close(fd);
}


