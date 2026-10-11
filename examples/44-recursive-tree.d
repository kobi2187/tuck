module _44_recursive_tree;

import rt = tuck_rt;

enum tuckˑtypeˑExprKind { Num, Neg, Add }

struct tuckˑtypeˑExpr_Num {
    long value;
}

struct tuckˑtypeˑExpr_Neg {
    tuckˑtypeˑExpr[] operand;
}

struct tuckˑtypeˑExpr_Add {
    tuckˑtypeˑExpr[] left;
    tuckˑtypeˑExpr[] right;
}

struct tuckˑtypeˑExpr {
    tuckˑtypeˑExprKind kind;
    union {
        tuckˑtypeˑExpr_Num tuckˑvariantˑnum;
        tuckˑtypeˑExpr_Neg tuckˑvariantˑneg;
        tuckˑtypeˑExpr_Add tuckˑvariantˑadd;
    }
    void tuckFree() {
        final switch (kind) {
        case tuckˑtypeˑExprKind.Num: rt.tuckDrop(tuckˑvariantˑnum); break;
        case tuckˑtypeˑExprKind.Neg: rt.tuckDrop(tuckˑvariantˑneg); break;
        case tuckˑtypeˑExprKind.Add: rt.tuckDrop(tuckˑvariantˑadd); break;
        }
    }
    tuckˑtypeˑExpr tuckDup() {
        tuckˑtypeˑExpr r = this;
        final switch (kind) {
        case tuckˑtypeˑExprKind.Num: r.tuckˑvariantˑnum = rt.tuckCopy(tuckˑvariantˑnum); break;
        case tuckˑtypeˑExprKind.Neg: r.tuckˑvariantˑneg = rt.tuckCopy(tuckˑvariantˑneg); break;
        case tuckˑtypeˑExprKind.Add: r.tuckˑvariantˑadd = rt.tuckCopy(tuckˑvariantˑadd); break;
        }
        return r;
    }
    bool opEquals(const tuckˑtypeˑExpr o) const {
        if (kind != o.kind) return false;
        final switch (kind) {
        case tuckˑtypeˑExprKind.Num: return tuckˑvariantˑnum == o.tuckˑvariantˑnum;
        case tuckˑtypeˑExprKind.Neg: return tuckˑvariantˑneg == o.tuckˑvariantˑneg;
        case tuckˑtypeˑExprKind.Add: return tuckˑvariantˑadd == o.tuckˑvariantˑadd;
        }
    }
}

long tuckˑfnˑeval(tuckˑtypeˑExpr e) {
    final switch (e.kind) {
    case tuckˑtypeˑExprKind.Num:
        return e.tuckˑvariantˑnum.value;
    case tuckˑtypeˑExprKind.Neg:
        return (0L - tuckˑfnˑeval(rt.tuckAt(e.tuckˑvariantˑneg.operand, 0L)));
    case tuckˑtypeˑExprKind.Add:
        return (tuckˑfnˑeval(rt.tuckAt(e.tuckˑvariantˑadd.left, 0L)) + tuckˑfnˑeval(rt.tuckAt(e.tuckˑvariantˑadd.right, 0L)));
    }
    return typeof(return).init;
}

long tuckˑfnˑdepth(tuckˑtypeˑExpr e) {
    final switch (e.kind) {
    case tuckˑtypeˑExprKind.Num:
        return 1L;
    case tuckˑtypeˑExprKind.Neg:
        return (1L + tuckˑfnˑdepth(rt.tuckAt(e.tuckˑvariantˑneg.operand, 0L)));
    case tuckˑtypeˑExprKind.Add:
        long tuckˑvˑl = tuckˑfnˑdepth(rt.tuckAt(e.tuckˑvariantˑadd.left, 0L));
        long tuckˑvˑr = tuckˑfnˑdepth(rt.tuckAt(e.tuckˑvariantˑadd.right, 0L));
        if ((tuckˑvˑl > tuckˑvˑr)) {
            return (1L + tuckˑvˑl);
        }
        return (1L + tuckˑvˑr);
    }
    return typeof(return).init;
}

long tuckˑfnˑmain() {
    tuckˑtypeˑExpr tuckˑvˑthree = tuckˑtypeˑExpr(kind: tuckˑtypeˑExprKind.Num, tuckˑvariantˑnum: tuckˑtypeˑExpr_Num(value: 3L));
    tuckˑtypeˑExpr tuckˑvˑfour = tuckˑtypeˑExpr(kind: tuckˑtypeˑExprKind.Num, tuckˑvariantˑnum: tuckˑtypeˑExpr_Num(value: 4L));
    tuckˑtypeˑExpr tuckˑvˑsum = tuckˑtypeˑExpr(kind: tuckˑtypeˑExprKind.Add, tuckˑvariantˑadd: tuckˑtypeˑExpr_Add(left: [tuckˑvˑthree], right: [tuckˑvˑfour]));
    tuckˑtypeˑExpr tuckˑvˑneg = tuckˑtypeˑExpr(kind: tuckˑtypeˑExprKind.Neg, tuckˑvariantˑneg: tuckˑtypeˑExpr_Neg(operand: [rt.tuckCopy(tuckˑvˑsum)]));
    tuckˑtypeˑExpr tuckˑvˑwhole = tuckˑtypeˑExpr(kind: tuckˑtypeˑExprKind.Add, tuckˑvariantˑadd: tuckˑtypeˑExpr_Add(left: [tuckˑvˑsum], right: [tuckˑvˑneg]));
    scope(exit) rt.tuckDrop(tuckˑvˑwhole);
    return ((tuckˑfnˑeval(tuckˑvˑwhole) + tuckˑfnˑdepth(tuckˑvˑwhole)) - 4L);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckLeakMark();
    auto mainRc = tuckˑfnˑmain();
    return rt.tuckLeakCheck(cast(int) mainRc);
}
