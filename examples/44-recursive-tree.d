module _44_recursive_tree;

import rt = tuck_rt;

enum tuck_ExprKind { Num, Neg, Add }

struct tuck_Expr_Num {
    long value;
}

struct tuck_Expr_Neg {
    tuck_Expr[] operand;
}

struct tuck_Expr_Add {
    tuck_Expr[] left;
    tuck_Expr[] right;
}

struct tuck_Expr {
    tuck_ExprKind kind;
    union {
        tuck_Expr_Num tuck_num;
        tuck_Expr_Neg tuck_neg;
        tuck_Expr_Add tuck_add;
    }
    bool opEquals(const tuck_Expr o) const {
        if (kind != o.kind) return false;
        final switch (kind) {
        case tuck_ExprKind.Num: return tuck_num == o.tuck_num;
        case tuck_ExprKind.Neg: return tuck_neg == o.tuck_neg;
        case tuck_ExprKind.Add: return tuck_add == o.tuck_add;
        }
    }
}

long tuck_eval(tuck_Expr e) {
    final switch (e.kind) {
    case tuck_ExprKind.Num:
        return e.tuck_num.value;
    case tuck_ExprKind.Neg:
        return (0L - tuck_eval(rt.tuckAt(e.tuck_neg.operand, 0L)));
    case tuck_ExprKind.Add:
        return (tuck_eval(rt.tuckAt(e.tuck_add.left, 0L)) + tuck_eval(rt.tuckAt(e.tuck_add.right, 0L)));
    }
    return typeof(return).init;
}

long tuck_depth(tuck_Expr e) {
    final switch (e.kind) {
    case tuck_ExprKind.Num:
        return 1L;
    case tuck_ExprKind.Neg:
        return (1L + tuck_depth(rt.tuckAt(e.tuck_neg.operand, 0L)));
    case tuck_ExprKind.Add:
        long tuck_l = tuck_depth(rt.tuckAt(e.tuck_add.left, 0L));
        long tuck_r = tuck_depth(rt.tuckAt(e.tuck_add.right, 0L));
        if ((tuck_l > tuck_r)) {
            return (1L + tuck_l);
        }
        return (1L + tuck_r);
    }
    return typeof(return).init;
}

long tuck_main() {
    tuck_Expr tuck_three = tuck_Expr(kind: tuck_ExprKind.Num, tuck_num: tuck_Expr_Num(value: 3L));
    tuck_Expr tuck_four = tuck_Expr(kind: tuck_ExprKind.Num, tuck_num: tuck_Expr_Num(value: 4L));
    tuck_Expr tuck_sum = tuck_Expr(kind: tuck_ExprKind.Add, tuck_add: tuck_Expr_Add(left: [tuck_three], right: [tuck_four]));
    tuck_Expr tuck_neg = tuck_Expr(kind: tuck_ExprKind.Neg, tuck_neg: tuck_Expr_Neg(operand: [tuck_sum]));
    tuck_Expr tuck_whole = tuck_Expr(kind: tuck_ExprKind.Add, tuck_add: tuck_Expr_Add(left: [tuck_sum], right: [tuck_neg]));
    return ((tuck_eval(tuck_whole) + tuck_depth(tuck_whole)) - 4L);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_main();
    return cast(int) mainRc;
}
