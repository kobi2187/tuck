import rt = tuck_rt;

struct Box {
    int[][] items;
}

struct Tree {
    int value;
    Tree[] children;
}

int main() {
    auto source = Box([[1, 2], [3, 4]]);
    auto copy = rt.tuckCopyG(source);
    copy.items[0][0] = 9;
    assert(source.items[0][0] == 1, "nested struct copy must not alias");
    assert(copy.items[0][0] == 9);
    int[][2] fixed = [[10], [20]];
    auto fixedCopy = rt.tuckCopyG(fixed);
    fixedCopy[0][0] = 30;
    assert(fixed[0][0] == 10);
    auto result = rt.tok(source);
    auto resultCopy = rt.tuckCopyG(result);
    resultCopy.value.items[1][1] = 42;
    assert(result.value.items[1][1] == 4);
    int[][] empty;
    assert(rt.tuckCopyG(empty).length == 0);
    auto absent = rt.tnone!Box();
    absent.value = source; // Deliberately poison the inactive payload.
    auto absentCopy = rt.tuckCopyG(absent);
    assert(absentCopy.status == rt.TuckStatus.Absent);
    assert(absentCopy.value.items.length == 0);
    auto failed = rt.terr!Box(123);
    failed.value = source;
    auto failedCopy = rt.tuckCopyG(failed);
    assert(failedCopy.err == 123 && failedCopy.value.items.length == 0);
    string label = "immutable";
    assert(rt.tuckCopyG(label) == label);
    auto tree = Tree(0, [Tree(1), Tree(2, [Tree(3)])]);
    auto treeCopy = rt.tuckCopyG(tree);
    treeCopy.children[1].children[0].value = 44;
    assert(tree.children[1].children[0].value == 3);
    return 0;
}
