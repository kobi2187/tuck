module mod_net;

import rt = tuck_rt;

struct TRec_net_fd_EC6A {
    long fd;
}

struct TRec_net_data_F9C9 {
    string data;
}

struct TRec_net_sent_18CB {
    long sent;
}

enum tuck_NetError { Refused, AddressInUse, Unreachable, Closed, IoFailed }

rt.TuckResult!(TRec_net_fd_EC6A) listen(long port) {
    return rt.listen!(rt.TuckResult!(TRec_net_fd_EC6A))(port);
}

rt.TuckResult!(TRec_net_fd_EC6A) accept(long fd) {
    return rt.accept!(rt.TuckResult!(TRec_net_fd_EC6A))(fd);
}

rt.TuckResult!(TRec_net_fd_EC6A) connect(string host, long port) {
    return rt.connect!(rt.TuckResult!(TRec_net_fd_EC6A))(host, port);
}

rt.TuckResult!(TRec_net_data_F9C9) recv(long fd, long max) {
    return rt.recv!(rt.TuckResult!(TRec_net_data_F9C9))(fd, max);
}

rt.TuckResult!(TRec_net_sent_18CB) send(long fd, string data) {
    return rt.send!(rt.TuckResult!(TRec_net_sent_18CB))(fd, data);
}

void close(long fd) {
    rt.close(fd);
}


