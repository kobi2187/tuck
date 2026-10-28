module mod_fmt;

import rt = tuck_rt;
import tuckˑmodˑstr = mod_str;
import tuckˑmodˑtext = mod_text;

struct tuckˑtypeˑStyle {
    long width;
    long precision;
    bool alignRight;
}

enum ShowableTag { Showable_is_tuckˑobjectˑTag }

struct Showable {
    ShowableTag tag;
    tuckˑobjectˑTag tuckˑobjectˑTagVal;
}

enum InspectableTag { Inspectable_is_tuckˑobjectˑTag }

struct Inspectable {
    InspectableTag tag;
    tuckˑobjectˑTag tuckˑobjectˑTagVal;
}

string tuckˑfnˑspaces(long count) {
    string[] tuckˑvˑparts = [];
    scope(exit) rt.tuckDrop(tuckˑvˑparts);
    foreach (tuckˑvˑi; 0L .. (count - 1L) + 1) {
        rt.tuckPush(tuckˑvˑparts, (" ").idup);
    }
    return tuckˑmodˑstr.joinStr(tuckˑvˑparts, "");
}

string tuckˑfnˑpad(string body, long width, bool alignRight) {
    scope(exit) rt.tuckDrop(body);
    long tuckˑvˑmissing = (width - tuckˑmodˑstr.byteCount(body));
    if ((tuckˑvˑmissing <= 0L)) {
        string tuckOwnTmp12 = body;
        body = typeof(body).init;
        return tuckOwnTmp12;
    }
    string tuckˑvˑfill = tuckˑfnˑspaces(tuckˑvˑmissing);
    scope(exit) rt.tuckDrop(tuckˑvˑfill);
    if (alignRight) {
        return (tuckˑvˑfill ~ body);
    }
    return (body ~ tuckˑvˑfill);
}

string tuckˑfnˑstyled(string body, tuckˑtypeˑStyle style) {
    string tuckˑvˑshown = (body).idup;
    if (((style.precision > 0L) && (tuckˑmodˑstr.byteCount(body) > style.precision))) {
        rt.TuckResult!(string) tuckˑvˑcut = tuckˑmodˑtext.tuckˑfnˑslice(body, 0L, style.precision);
        scope(exit) rt.tuckDrop(tuckˑvˑcut);
        if ((tuckˑvˑcut.status == rt.TuckStatus.Ok)) {
            rt.tuckReplace(tuckˑvˑshown, tuckˑvˑcut.value);
            tuckˑvˑcut.value = typeof(tuckˑvˑcut.value).init;
        }
    }
    return tuckˑfnˑpad(tuckˑvˑshown, style.width, style.alignRight);
}

string tuckˑfnˑrender(Showable v) {
    return ((Showable v) {
    switch (v.tag) {
        case ShowableTag.Showable_is_tuckˑobjectˑTag:
            auto tmp = v.tuckˑobjectˑTagVal;
            return tuckˑobjectˑTagˑshow(tmp);
        default: assert(0, "unreachable interface tag");
    }
})(v);
}

string tuckˑfnˑrenderDebug(Inspectable v) {
    return ((Inspectable v) {
    switch (v.tag) {
        case InspectableTag.Inspectable_is_tuckˑobjectˑTag:
            auto tmp = v.tuckˑobjectˑTagVal;
            return tuckˑobjectˑTagˑinspect(tmp);
        default: assert(0, "unreachable interface tag");
    }
})(v);
}

struct tuckˑobjectˑTag {
    string name;
}

string tuckˑobjectˑTagˑshow(tuckˑobjectˑTag self) {
    return (self.name).idup;
}

string tuckˑobjectˑTagˑinspect(tuckˑobjectˑTag self) {
    string tuckOwnTmp13 = ("Tag(" ~ self.name);
    scope(exit) rt.tuckDrop(tuckOwnTmp13);
    return (tuckOwnTmp13 ~ ")");
}


long tuckˑfnˑcheckPad() {
    string tuckOwnTmp14 = tuckˑfnˑpad(("ab").idup, 5L, false);
    scope(exit) rt.tuckDrop(tuckOwnTmp14);
    if ((tuckOwnTmp14 != "ab   ")) {
        return 1L;
    }
    string tuckOwnTmp15 = tuckˑfnˑpad(("ab").idup, 5L, true);
    scope(exit) rt.tuckDrop(tuckOwnTmp15);
    if ((tuckOwnTmp15 != "   ab")) {
        return 2L;
    }
    string tuckOwnTmp16 = tuckˑfnˑpad(("abcdef").idup, 3L, true);
    scope(exit) rt.tuckDrop(tuckOwnTmp16);
    if ((tuckOwnTmp16 != "abcdef")) {
        return 3L;
    }
    string tuckOwnTmp17 = tuckˑfnˑpad(("").idup, 2L, false);
    scope(exit) rt.tuckDrop(tuckOwnTmp17);
    if ((tuckOwnTmp17 != "  ")) {
        return 4L;
    }
    return 0L;
}

long tuckˑfnˑcheckStyled() {
    tuckˑtypeˑStyle tuckˑvˑcut = tuckˑtypeˑStyle(width: 6L, precision: 3L, alignRight: true);
    string tuckOwnTmp18 = tuckˑfnˑstyled("abcdef", tuckˑvˑcut);
    scope(exit) rt.tuckDrop(tuckOwnTmp18);
    if ((tuckOwnTmp18 != "   abc")) {
        return 5L;
    }
    tuckˑtypeˑStyle tuckˑvˑall = tuckˑtypeˑStyle(width: 0L, precision: 0L, alignRight: false);
    string tuckOwnTmp19 = tuckˑfnˑstyled("abcdef", tuckˑvˑall);
    scope(exit) rt.tuckDrop(tuckOwnTmp19);
    if ((tuckOwnTmp19 != "abcdef")) {
        return 6L;
    }
    return 0L;
}

long tuckˑfnˑcheckRender() {
    tuckˑobjectˑTag tuckˑvˑt = tuckˑobjectˑTag(name: ("x").idup);
    scope(exit) rt.tuckDrop(tuckˑvˑt);
    string tuckOwnTmp20 = tuckˑfnˑrender(Showable(ShowableTag.Showable_is_tuckˑobjectˑTag, tuckˑobjectˑTagVal: tuckˑvˑt));
    scope(exit) rt.tuckDrop(tuckOwnTmp20);
    if ((tuckOwnTmp20 != "x")) {
        return 7L;
    }
    string tuckOwnTmp21 = tuckˑfnˑrenderDebug(Inspectable(InspectableTag.Inspectable_is_tuckˑobjectˑTag, tuckˑobjectˑTagVal: tuckˑvˑt));
    scope(exit) rt.tuckDrop(tuckOwnTmp21);
    if ((tuckOwnTmp21 != "Tag(x)")) {
        return 8L;
    }
    return 0L;
}

long tuckˑfnˑmain() {
    long tuckˑvˑp = tuckˑfnˑcheckPad();
    if ((tuckˑvˑp != 0L)) {
        return tuckˑvˑp;
    }
    long tuckˑvˑs = tuckˑfnˑcheckStyled();
    if ((tuckˑvˑs != 0L)) {
        return tuckˑvˑs;
    }
    return tuckˑfnˑcheckRender();
}

