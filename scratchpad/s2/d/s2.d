module s2;

import rt = tuck_rt;

enum tuck_ExprNodeKind { Num, Add }

struct tuck_ExprNode_Num {
    long value;
}

struct tuck_ExprNode_Add {
    long left;
    long right;
}

struct tuck_ExprNode {
    tuck_ExprNodeKind kind;
    union {
        tuck_ExprNode_Num tuck_num;
        tuck_ExprNode_Add tuck_add;
    }
}

struct tuck_Expr {
    tuck_ExprNode[] slots;
    long root;
}

tuck_Expr tuck_mkNum(long value) {
    return tuck_Expr(slots: [tuck_ExprNode(kind: tuck_ExprNodeKind.Num, tuck_num: tuck_ExprNode_Num(value: value))], root: 0);
}

tuck_ExprNode tuck_shift(tuck_ExprNode n, long by) {
    final switch (n.kind) {
    case tuck_ExprNodeKind.Num:
        return n;
    case tuck_ExprNodeKind.Add:
        return tuck_ExprNode(kind: tuck_ExprNodeKind.Add, tuck_add: tuck_ExprNode_Add(left: (n.tuck_add.left + by), right: (n.tuck_add.right + by)));
    }
    return typeof(return).init;
}

tuck_Expr tuck_mkAdd(tuck_Expr left, tuck_Expr right) {
    tuck_ExprNode[] tuck_slots = (left.slots).dup;
    long tuck_off = 0;
    foreach (tuck_s; right.slots) {
        tuck_slots = rt.push(tuck_slots, tuck_shift(tuck_s, 0));
    }
    return tuck_Expr(slots: tuck_slots, root: 0);
}

long tuck_main() {
    tuck_Expr tuck_a = (() { auto tuckRecDup1 = tuck_mkNum(3); tuckRecDup1.slots = tuckRecDup1.slots.dup; return tuckRecDup1; })();
    return (rt.tuckAt(tuck_a.slots, tuck_a.root).tuck_num.value - 3);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_main();
    return cast(int) mainRc;
}
