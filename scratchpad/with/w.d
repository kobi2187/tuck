module w;

import rt = tuck_rt;

struct tuck_Task {
    string title;
    bool done;
    long score;
}

tuck_Task tuck_complete(tuck_Task self) {
    return tuck_Task(title: self.title, done: true, score: self.score);
}

tuck_Task tuck_rescore(tuck_Task self, long n) {
    return tuck_Task(title: self.title, done: false, score: n);
}

long tuck_main() {
    tuck_Task tuck_t = tuck_Task(title: "write it", done: false, score: 1);
    tuck_Task tuck_d = tuck_complete(tuck_t);
    tuck_Task tuck_r = tuck_rescore(tuck_d, 7);
    if ((tuck_d.done && ((tuck_r.score == 7) && (!tuck_r.done && (tuck_r.title == "write it"))))) {
        return 0;
    }
    return 1;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_main();
    return cast(int) mainRc;
}
