module mod_net;

import rt = tuck_rt;

struct TRec_net_fd(T_fd) {
    T_fd fd;
}

struct TRec_net_data(T_data) {
    T_data data;
}

struct TRec_net_sent(T_sent) {
    T_sent sent;
}

enum tuckˑtypeˑNetError { Refused, AddressInUse, Unreachable, Closed, IoFailed }

rt.TuckResult!(TRec_net_fd!(long)) listen(long port) {
    return rt.listen!(rt.TuckResult!(TRec_net_fd!(long)))(port);
}

rt.TuckResult!(TRec_net_fd!(long)) accept(long fd) {
    return rt.accept!(rt.TuckResult!(TRec_net_fd!(long)))(fd);
}

rt.TuckResult!(TRec_net_fd!(long)) connect(string host, long port) {
    return rt.connect!(rt.TuckResult!(TRec_net_fd!(long)))(host, port);
}

rt.TuckResult!(TRec_net_data!(string)) recv(long fd, long max) {
    return rt.recv!(rt.TuckResult!(TRec_net_data!(string)))(fd, max);
}

rt.TuckResult!(TRec_net_sent!(long)) send(long fd, string data) {
    return rt.send!(rt.TuckResult!(TRec_net_sent!(long)))(fd, data);
}

void close(long fd) {
    rt.close(fd);
}


