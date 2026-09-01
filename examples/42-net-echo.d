module _42_net_echo;

import rt = tuck_rt;
import scheduler = mod_scheduler;
import net = mod_net;

enum tuck_ResultMsgKind { msgPut }

struct tuck_ResultMsg {
    tuck_ResultMsgKind kind;
    long c;
}

struct tuck_Result {
    long code;
    bool ready;
    rt.Mailbox!(tuck_ResultMsg, 8) mailbox;
}

__gshared tuck_Result tuck_ResultSingleton;

void handleMsg_tuck_Result(ref tuck_Result self, tuck_ResultMsg msg) {
    final switch (msg.kind) {
        case tuck_ResultMsgKind.msgPut:
            auto c = msg.c;
            self.code = c;
            self.ready = true;
            break;
    }
}

bool drain_tuck_Result() {
    bool did = false;
    tuck_ResultMsg msg;
    while (rt.dequeue(tuck_ResultSingleton.mailbox, msg)) {
        handleMsg_tuck_Result(tuck_ResultSingleton, msg);
        did = true;
    }
    return did;
}

void sendPut_tuck_Result(ref tuck_Result self, long c) {
    cast(void) rt.enqueue(self.mailbox, tuck_ResultMsg(tuck_ResultMsgKind.msgPut, c));
    rt.tuckNotifySend();
}


void tuck_serve(long lfd) {
    rt.TuckResult!(net.TRec_net_fd_EC6A) c = net.accept(lfd);
    if ((c.status == rt.TuckStatus.Ok)) {
        rt.TuckResult!(net.TRec_net_data_F9C9) req = net.recv(c.value.fd, 256);
        rt.TuckResult!(net.TRec_net_sent_18CB) s = net.send(c.value.fd, "pong");
        net.close(c.value.fd);
    }
    return;
}

void tuck_client(long port) {
    rt.TuckResult!(net.TRec_net_fd_EC6A) c = net.connect("127.0.0.1", port);
    if ((c.status == rt.TuckStatus.Ok)) {
        rt.TuckResult!(net.TRec_net_sent_18CB) s = net.send(c.value.fd, "ping");
        rt.TuckResult!(net.TRec_net_data_F9C9) r = net.recv(c.value.fd, 256);
        net.close(c.value.fd);
        if ((r.status == rt.TuckStatus.Ok)) {
            if ((r.value.data == "pong")) {
                sendPut_tuck_Result(tuck_ResultSingleton, 42);
                return;
            }
        }
        sendPut_tuck_Result(tuck_ResultSingleton, 3);
        return;
    }
    sendPut_tuck_Result(tuck_ResultSingleton, 4);
    return;
}

bool tuck_done() {
    return tuck_ResultSingleton.ready;
}

long tuck_main() {
    rt.TuckResult!(net.TRec_net_fd_EC6A) l = net.listen(34593);
    if ((l.status == rt.TuckStatus.Ok)) {
        rt.tuckSpawn({ cast(void) tuck_serve(l.value.fd); });
        rt.tuckSpawn({ cast(void) tuck_client(34593); });
        scheduler.waitUntil(&tuck_done);
        net.close(l.value.fd);
        scheduler.stop();
        return tuck_ResultSingleton.code;
    }
    return 1;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    rt.tuckStartActor(&drain_tuck_Result);
    auto mainRc = tuck_main();
    rt.tuckRun();
    return cast(int) mainRc;
}
