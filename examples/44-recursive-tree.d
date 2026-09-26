module _44_recursive_tree;

import rt = tuck_rt;

enum tuck_type_ExprKind { Num, Neg, Add }

struct tuck_type_Expr_Num {
    long value;
}

struct tuck_type_Expr_Neg {
    tuck_type_Expr[] operand;
}

struct tuck_type_Expr_Add {
    tuck_type_Expr[] left;
    tuck_type_Expr[] right;
}

struct tuck_type_Expr {
    tuck_type_ExprKind kind;
    union {
        tuck_type_Expr_Num tuck_num;
        tuck_type_Expr_Neg tuck_neg;
        tuck_type_Expr_Add tuck_add;
    }
    bool opEquals(const tuck_type_Expr o) const {
        if (kind != o.kind) return false;
        final switch (kind) {
        case tuck_type_ExprKind.Num: return tuck_num == o.tuck_num;
        case tuck_type_ExprKind.Neg: return tuck_neg == o.tuck_neg;
        case tuck_type_ExprKind.Add: return tuck_add == o.tuck_add;
        }
    }
}

long tuck_fn_eval(tuck_type_Expr e) {
    final switch (e.kind) {
    case tuck_type_ExprKind.Num:
        return e.tuck_num.value;
    case tuck_type_ExprKind.Neg:
        return (0L - tuck_fn_eval(rt.tuckAt(e.tuck_neg.operand, 0L)));
    case tuck_type_ExprKind.Add:
        return (tuck_fn_eval(rt.tuckAt(e.tuck_add.left, 0L)) + tuck_fn_eval(rt.tuckAt(e.tuck_add.right, 0L)));
    }
    return typeof(return).init;
}

long tuck_fn_depth(tuck_type_Expr e) {
    final switch (e.kind) {
    case tuck_type_ExprKind.Num:
        return 1L;
    case tuck_type_ExprKind.Neg:
        return (1L + tuck_fn_depth(rt.tuckAt(e.tuck_neg.operand, 0L)));
    case tuck_type_ExprKind.Add:
        long tuck_l = tuck_fn_depth(rt.tuckAt(e.tuck_add.left, 0L));
        long tuck_r = tuck_fn_depth(rt.tuckAt(e.tuck_add.right, 0L));
        if ((tuck_l > tuck_r)) {
            return (1L + tuck_l);
        }
        return (1L + tuck_r);
    }
    return typeof(return).init;
}

long tuck_fn_main() {
    tuck_type_Expr tuck_three = tuck_type_Expr(kind: tuck_type_ExprKind.Num, tuck_num: tuck_type_Expr_Num(value: 3L));
    tuck_type_Expr tuck_four = tuck_type_Expr(kind: tuck_type_ExprKind.Num, tuck_num: tuck_type_Expr_Num(value: 4L));
    tuck_type_Expr tuck_sum = tuck_type_Expr(kind: tuck_type_ExprKind.Add, tuck_add: tuck_type_Expr_Add(left: [tuck_three], right: [tuck_four]));
    tuck_type_Expr tuck_neg = tuck_type_Expr(kind: tuck_type_ExprKind.Neg, tuck_neg: tuck_type_Expr_Neg(operand: [tuck_sum]));
    tuck_type_Expr tuck_whole = tuck_type_Expr(kind: tuck_type_ExprKind.Add, tuck_add: tuck_type_Expr_Add(left: [tuck_sum], right: [tuck_neg]));
    return ((tuck_fn_eval(tuck_whole) + tuck_fn_depth(tuck_whole)) - 4L);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_fn_main();
    return cast(int) mainRc;
}
