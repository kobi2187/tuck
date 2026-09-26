module _42_net_echo;

import rt = tuck_rt;
import scheduler = mod_scheduler;
import net = mod_net;

enum tuck_type_ResultMsgKind { msgPut }

struct tuck_type_ResultMsg {
    tuck_type_ResultMsgKind tuckTag;
    long c;
}

struct tuck_type_Result {
    long code;
    bool ready;
    rt.Mailbox!(tuck_type_ResultMsg, 8) mailbox;
}

__gshared tuck_type_Result tuck_type_ResultSingleton;

shared static this() {
    tuck_type_ResultSingleton.code = 0L;
    tuck_type_ResultSingleton.ready = false;
}

void handleMsg_tuck_type_Result(ref tuck_type_Result self, tuck_type_ResultMsg msg) {
    final switch (msg.tuckTag) {
        case tuck_type_ResultMsgKind.msgPut:
            auto c = msg.c;
            self.code = c;
            self.ready = true;
            break;
    }
}

__gshared void* tuck_type_ResultSlot;

bool drain_tuck_type_Result() {
    bool did = false;
    foreach (ref msg; tuck_type_ResultSingleton.mailbox) {
        handleMsg_tuck_type_Result(tuck_type_ResultSingleton, msg);
        rt.tuckCheckWaiters();
        did = true;
    }
    return did;
}

void sendPut_tuck_type_Result(ref tuck_type_Result self, long c) {
    cast(void) rt.enqueue(self.mailbox, tuck_type_ResultMsg(tuckTag: tuck_type_ResultMsgKind.msgPut, c: c));
    rt.tuckNotifySend(tuck_type_ResultSlot);
}


void tuck_fn_serve(long lfd) {
    rt.TuckResult!(net.TRec_net_fd!(long)) tuck_c = net.accept(lfd);
    if ((tuck_c.status == rt.TuckStatus.Ok)) {
        net.recv(tuck_c.value.fd, 256L);
        net.send(tuck_c.value.fd, "pong");
        net.close(tuck_c.value.fd);
    }
    return;
}

void tuck_fn_client(long port) {
    rt.TuckResult!(net.TRec_net_fd!(long)) tuck_c = net.connect("127.0.0.1", port);
    if ((tuck_c.status == rt.TuckStatus.Ok)) {
        net.send(tuck_c.value.fd, "ping");
        rt.TuckResult!(net.TRec_net_data!(string)) tuck_r = net.recv(tuck_c.value.fd, 256L);
        net.close(tuck_c.value.fd);
        if ((tuck_r.status == rt.TuckStatus.Ok)) {
            if ((tuck_r.value.data == "pong")) {
                sendPut_tuck_type_Result(tuck_type_ResultSingleton, 42L);
                return;
            }
        }
        sendPut_tuck_type_Result(tuck_type_ResultSingleton, 3L);
        return;
    }
    sendPut_tuck_type_Result(tuck_type_ResultSingleton, 4L);
    return;
}

bool tuck_fn_done() {
    return tuck_type_ResultSingleton.ready;
}

long tuck_fn_main() {
    rt.TuckResult!(net.TRec_net_fd!(long)) tuck_l = net.listen(34593L);
    if ((tuck_l.status == rt.TuckStatus.Ok)) {
        rt.tuckSpawn({ cast(void) tuck_fn_serve(tuck_l.value.fd); });
        rt.tuckSpawn({ cast(void) tuck_fn_client(34593L); });
        rt.tuckWaitOn(tuck_type_ResultSlot, &tuck_fn_done);
        net.close(tuck_l.value.fd);
        scheduler.stop();
        return tuck_type_ResultSingleton.code;
    }
    return 1L;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    tuck_type_ResultSlot = rt.tuckStartActor(&drain_tuck_type_Result);
    auto mainRc = tuck_fn_main();
    rt.tuckRun();
    rt.tuckDrainActors();
    return cast(int) mainRc;
}
