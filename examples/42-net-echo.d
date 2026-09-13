module _42_net_echo;

import rt = tuck_rt;
import scheduler = mod_scheduler;
import net = mod_net;

enum tuck_ResultMsgKind { msgPut }

struct tuck_ResultMsg {
    tuck_ResultMsgKind tuckTag;
    long c;
}

struct tuck_Result {
    long code;
    bool ready;
    rt.Mailbox!(tuck_ResultMsg, 8) mailbox;
}

__gshared tuck_Result tuck_ResultSingleton;

void handleMsg_tuck_Result(ref tuck_Result self, tuck_ResultMsg msg) {
    final switch (msg.tuckTag) {
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
    cast(void) rt.enqueue(self.mailbox, tuck_ResultMsg(tuckTag: tuck_ResultMsgKind.msgPut, c: c));
    rt.tuckNotifySend();
}


void tuck_serve(long lfd) {
    rt.TuckResult!(net.TRec_net_fd!(long)) tuck_c = net.accept(lfd);
    if ((tuck_c.status == rt.TuckStatus.Ok)) {
        rt.TuckResult!(net.TRec_net_data!(string)) tuck_req = net.recv(tuck_c.value.fd, 256L);
        rt.TuckResult!(net.TRec_net_sent!(long)) tuck_s = net.send(tuck_c.value.fd, "pong");
        net.close(tuck_c.value.fd);
    }
    return;
}

void tuck_client(long port) {
    rt.TuckResult!(net.TRec_net_fd!(long)) tuck_c = net.connect("127.0.0.1", port);
    if ((tuck_c.status == rt.TuckStatus.Ok)) {
        rt.TuckResult!(net.TRec_net_sent!(long)) tuck_s = net.send(tuck_c.value.fd, "ping");
        rt.TuckResult!(net.TRec_net_data!(string)) tuck_r = net.recv(tuck_c.value.fd, 256L);
        net.close(tuck_c.value.fd);
        if ((tuck_r.status == rt.TuckStatus.Ok)) {
            if ((tuck_r.value.data == "pong")) {
                sendPut_tuck_Result(tuck_ResultSingleton, 42L);
                return;
            }
        }
        sendPut_tuck_Result(tuck_ResultSingleton, 3L);
        return;
    }
    sendPut_tuck_Result(tuck_ResultSingleton, 4L);
    return;
}

bool tuck_done() {
    return tuck_ResultSingleton.ready;
}

long tuck_main() {
    rt.TuckResult!(net.TRec_net_fd!(long)) tuck_l = net.listen(34593L);
    if ((tuck_l.status == rt.TuckStatus.Ok)) {
        rt.tuckSpawn({ cast(void) tuck_serve(tuck_l.value.fd); });
        rt.tuckSpawn({ cast(void) tuck_client(34593L); });
        scheduler.waitUntil(&tuck_done);
        net.close(tuck_l.value.fd);
        scheduler.stop();
        return tuck_ResultSingleton.code;
    }
    return 1L;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    rt.tuckStartActor(&drain_tuck_Result);
    auto mainRc = tuck_main();
    rt.tuckRun();
    return cast(int) mainRc;
}
