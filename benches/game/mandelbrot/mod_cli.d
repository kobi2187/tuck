module mod_cli;

import rt = tuck_rt;
import tuckˑmodˑconvert = mod_convert;
import tuckˑmodˑfmt = mod_fmt;
import tuckˑmodˑseq = mod_seq;
import tuckˑmodˑshapes_mandelbrot = mod_shapes_mandelbrot;
import tuckˑmodˑstr = mod_str;
import tuckˑmodˑsys = mod_sys;
import tuckˑmodˑtext = mod_text;

enum tuckˑtypeˑArgKind { AFlag, AText, ANumber }

struct tuckˑtypeˑArgSpec {
    string name;
    string shortName;
    tuckˑtypeˑArgKind kind;
    string help;
    bool required;
}

struct tuckˑtypeˑCommand {
    string name;
    string help;
    tuckˑtypeˑArgSpec[] args;
    tuckˑtypeˑCommand[] subcommands;
}

struct tuckˑtypeˑEntry {
    string key;
    string value;
}

struct tuckˑtypeˑArgs {
    tuckˑtypeˑEntry[] named;
    string[] positional;
    string subcommand;
}

enum tuckˑtypeˑColour { Plain, Red, Green, Yellow, Blue }

rt.TuckResult!(tuckˑtypeˑArgSpec) tuckˑfnˑspecNamed(tuckˑtypeˑCommand c, string name) {
    foreach (tuckˑvˑi; 0L .. (cast(long) c.args.length - 1L) + 1) {
        if ((rt.tuckAt(c.args, tuckˑvˑi).name == name)) {
            return rt.tok(rt.tuckCopy(rt.tuckAt(c.args, tuckˑvˑi)));
        }
    }
    return rt.tnone!(tuckˑtypeˑArgSpec)();
}

rt.TuckResult!(tuckˑtypeˑArgSpec) tuckˑfnˑspecShort(tuckˑtypeˑCommand c, string letter) {
    foreach (tuckˑvˑi; 0L .. (cast(long) c.args.length - 1L) + 1) {
        if ((rt.tuckAt(c.args, tuckˑvˑi).shortName == letter)) {
            return rt.tok(rt.tuckCopy(rt.tuckAt(c.args, tuckˑvˑi)));
        }
    }
    return rt.tnone!(tuckˑtypeˑArgSpec)();
}

rt.TuckResult!(tuckˑtypeˑCommand) tuckˑfnˑsubcommandNamed(tuckˑtypeˑCommand c, string name) {
    foreach (tuckˑvˑi; 0L .. (cast(long) c.subcommands.length - 1L) + 1) {
        if ((rt.tuckAt(c.subcommands, tuckˑvˑi).name == name)) {
            return rt.tok(rt.tuckCopy(rt.tuckAt(c.subcommands, tuckˑvˑi)));
        }
    }
    return rt.tnone!(tuckˑtypeˑCommand)();
}

rt.TuckResult!(string) tuckˑfnˑtextOf(tuckˑtypeˑArgs a, string name) {
    foreach (tuckˑvˑi; 0L .. (cast(long) a.named.length - 1L) + 1) {
        if ((rt.tuckAt(a.named, tuckˑvˑi).key == name)) {
            return rt.tok((rt.tuckAt(a.named, tuckˑvˑi).value).idup);
        }
    }
    return rt.tnone!(string)();
}

rt.TuckResult!(long) tuckˑfnˑnumberOf(tuckˑtypeˑArgs a, string name) {
    rt.TuckResult!(string) tuckˑvˑt = tuckˑfnˑtextOf(a, name);
    scope(exit) rt.tuckDrop(tuckˑvˑt);
    if (!(tuckˑvˑt.status == rt.TuckStatus.Ok)) {
        return rt.tnone!(long)();
    }
    return tuckˑmodˑconvert.tuckˑfnˑparseInt(tuckˑvˑt.value);
}

bool tuckˑfnˑhasFlag(tuckˑtypeˑArgs a, string name) {
    rt.TuckResult!(string) tuckˑvˑt = tuckˑfnˑtextOf(a, name);
    scope(exit) rt.tuckDrop(tuckˑvˑt);
    return (tuckˑvˑt.status == rt.TuckStatus.Ok);
}

bool tuckˑfnˑisNumber(string t) {
    rt.TuckResult!(long) tuckˑvˑn = tuckˑmodˑconvert.tuckˑfnˑparseInt(t);
    return (tuckˑvˑn.status == rt.TuckStatus.Ok);
}

bool tuckˑfnˑaccepts(tuckˑtypeˑArgSpec spec, string value) {
    final switch (spec.kind) {
    case tuckˑtypeˑArgKind.AFlag:
        return false;
    case tuckˑtypeˑArgKind.AText:
        return true;
    case tuckˑtypeˑArgKind.ANumber:
        return tuckˑfnˑisNumber(value);
    }
    return typeof(return).init;
}

bool tuckˑfnˑisFlag(tuckˑtypeˑArgSpec spec) {
    final switch (spec.kind) {
    case tuckˑtypeˑArgKind.AFlag:
        return true;
    case tuckˑtypeˑArgKind.AText:
        return false;
    case tuckˑtypeˑArgKind.ANumber:
        return false;
    }
    return typeof(return).init;
}

bool tuckˑfnˑrequiredPresent(tuckˑtypeˑCommand c, tuckˑtypeˑArgs a) {
    foreach (tuckˑvˑi; 0L .. (cast(long) c.args.length - 1L) + 1) {
        if (rt.tuckAt(c.args, tuckˑvˑi).required) {
            if (!tuckˑfnˑhasFlag(a, rt.tuckAt(c.args, tuckˑvˑi).name)) {
                return false;
            }
        }
    }
    return true;
}

tuckˑtypeˑArgs tuckˑfnˑwithEntry(tuckˑtypeˑArgs a, string key, string value) {
    a = rt.tuckCopy(a);
    key = rt.tuckCopy(key);
    value = rt.tuckCopy(value);
    return tuckˑfnˑwithEntry_moved(a, key, value);
}

tuckˑtypeˑArgs tuckˑfnˑwithEntry_moved(tuckˑtypeˑArgs a, string key, string value) {
    scope(exit) rt.tuckDrop(a.named);
    tuckˑtypeˑEntry tuckˑvˑe = tuckˑtypeˑEntry(key: key, value: value);
    tuckˑtypeˑEntry[] tuckˑvˑgrown = tuckˑmodˑseq.push(a.named, tuckˑvˑe);
    return tuckˑtypeˑArgs(named: tuckˑvˑgrown, subcommand: a.subcommand, positional: a.positional);
}

tuckˑtypeˑArgs tuckˑfnˑwithPositional(tuckˑtypeˑArgs a, string word) {
    a = rt.tuckCopy(a);
    word = rt.tuckCopy(word);
    return tuckˑfnˑwithPositional_moved(a, word);
}

tuckˑtypeˑArgs tuckˑfnˑwithPositional_moved(tuckˑtypeˑArgs a, string word) {
    scope(exit) rt.tuckDrop(a.positional);
    string[] tuckˑvˑgrown = tuckˑmodˑseq.push(a.positional, word);
    return tuckˑtypeˑArgs(positional: tuckˑvˑgrown, subcommand: a.subcommand, named: a.named);
}

string[] tuckˑfnˑcommandLine() {
    string[] tuckˑvˑout = [];
    tuckˑmodˑshapes_mandelbrot.TRec_total!(long) tuckˑvˑn = tuckˑmodˑsys.argCount();
    foreach (tuckˑvˑi; 1L .. tuckˑvˑn.total + 1) {
        tuckˑmodˑshapes_mandelbrot.TRec_arg!(string) tuckˑvˑa = tuckˑmodˑsys.argAt(tuckˑvˑi);
        rt.tuckPush(tuckˑvˑout, tuckˑvˑa.arg);
    }
    return tuckˑvˑout;
}

rt.TuckResult!(tuckˑtypeˑArgs) tuckˑfnˑtryParse(tuckˑtypeˑCommand c, string[] argv) {
    tuckˑtypeˑEntry[] tuckˑvˑempty = [];
    string[] tuckˑvˑwords = [];
    tuckˑtypeˑArgs tuckˑvˑa = tuckˑtypeˑArgs(named: tuckˑvˑempty, positional: tuckˑvˑwords, subcommand: ("").idup);
    scope(exit) rt.tuckDrop(tuckˑvˑa.named);
    scope(exit) rt.tuckDrop(tuckˑvˑa.subcommand);
    scope(exit) rt.tuckDrop(tuckˑvˑa.positional);
    long tuckˑvˑi = 0L;
    while ((tuckˑvˑi < cast(long) argv.length)) {
        string tuckˑvˑarg = (rt.tuckAt(argv, tuckˑvˑi)).idup;
        scope(exit) rt.tuckDrop(tuckˑvˑarg);
        tuckˑvˑi = (tuckˑvˑi + 1L);
        if (tuckˑmodˑtext.tuckˑfnˑstartsWith(tuckˑvˑarg, "--")) {
            long tuckˑvˑargLen = tuckˑmodˑstr.byteCount(tuckˑvˑarg);
            rt.TuckResult!(string) tuckˑvˑbody = tuckˑmodˑtext.tuckˑfnˑslice(tuckˑvˑarg, 2L, tuckˑvˑargLen);
            scope(exit) rt.tuckDrop(tuckˑvˑbody);
            if (!(tuckˑvˑbody.status == rt.TuckStatus.Ok)) {
                return rt.tnone!(tuckˑtypeˑArgs)();
            }
            string tuckˑvˑname = (tuckˑvˑbody.value).idup;
            scope(exit) rt.tuckDrop(tuckˑvˑname);
            string tuckˑvˑattached = ("").idup;
            scope(exit) rt.tuckDrop(tuckˑvˑattached);
            bool tuckˑvˑhasAttached = false;
            rt.TuckResult!(long) tuckˑvˑeq = tuckˑmodˑtext.tuckˑfnˑfind(tuckˑvˑbody.value, "=");
            if ((tuckˑvˑeq.status == rt.TuckStatus.Ok)) {
                rt.TuckResult!(string) tuckˑvˑn = tuckˑmodˑtext.tuckˑfnˑslice(tuckˑvˑbody.value, 0L, tuckˑvˑeq.value);
                scope(exit) rt.tuckDrop(tuckˑvˑn);
                long tuckˑvˑbodyLen = tuckˑmodˑstr.byteCount(tuckˑvˑbody.value);
                rt.TuckResult!(string) tuckˑvˑv = tuckˑmodˑtext.tuckˑfnˑslice(tuckˑvˑbody.value, (tuckˑvˑeq.value + 1L), tuckˑvˑbodyLen);
                scope(exit) rt.tuckDrop(tuckˑvˑv);
                if (!(tuckˑvˑn.status == rt.TuckStatus.Ok)) {
                    return rt.tnone!(tuckˑtypeˑArgs)();
                }
                if (!(tuckˑvˑv.status == rt.TuckStatus.Ok)) {
                    return rt.tnone!(tuckˑtypeˑArgs)();
                }
                rt.tuckReplace(tuckˑvˑname, tuckˑvˑn.value);
                tuckˑvˑn.value = typeof(tuckˑvˑn.value).init;
                rt.tuckReplace(tuckˑvˑattached, tuckˑvˑv.value);
                tuckˑvˑv.value = typeof(tuckˑvˑv.value).init;
                tuckˑvˑhasAttached = true;
            }
            rt.TuckResult!(tuckˑtypeˑArgSpec) tuckˑvˑspec = tuckˑfnˑspecNamed(c, tuckˑvˑname);
            scope(exit) rt.tuckDrop(tuckˑvˑspec);
            if (!(tuckˑvˑspec.status == rt.TuckStatus.Ok)) {
                return rt.tnone!(tuckˑtypeˑArgs)();
            }
            if (tuckˑfnˑisFlag(tuckˑvˑspec.value)) {
                tuckˑvˑa = tuckˑfnˑwithEntry_moved(tuckˑvˑa, tuckˑvˑname, ("true").idup);
                tuckˑvˑname = typeof(tuckˑvˑname).init;
            } else {
                string tuckˑvˑvalue = tuckˑvˑattached;
                scope(exit) rt.tuckDrop(tuckˑvˑvalue);
                tuckˑvˑattached = typeof(tuckˑvˑattached).init;
                if (!tuckˑvˑhasAttached) {
                    if ((tuckˑvˑi >= cast(long) argv.length)) {
                        return rt.tnone!(tuckˑtypeˑArgs)();
                    }
                    rt.tuckReplace(tuckˑvˑvalue, (rt.tuckAt(argv, tuckˑvˑi)).idup);
                    tuckˑvˑi = (tuckˑvˑi + 1L);
                }
                if (!tuckˑfnˑaccepts(tuckˑvˑspec.value, tuckˑvˑvalue)) {
                    return rt.tnone!(tuckˑtypeˑArgs)();
                }
                tuckˑvˑa = tuckˑfnˑwithEntry_moved(tuckˑvˑa, tuckˑvˑname, tuckˑvˑvalue);
                tuckˑvˑname = typeof(tuckˑvˑname).init;
                tuckˑvˑvalue = typeof(tuckˑvˑvalue).init;
            }
        } else if ((tuckˑmodˑtext.tuckˑfnˑstartsWith(tuckˑvˑarg, "-") && (tuckˑmodˑstr.byteCount(tuckˑvˑarg) == 2L))) {
            string tuckˑvˑletter = tuckˑmodˑstr.charAt(tuckˑvˑarg, 1L);
            scope(exit) rt.tuckDrop(tuckˑvˑletter);
            rt.TuckResult!(tuckˑtypeˑArgSpec) tuckˑvˑspecˑ1 = tuckˑfnˑspecShort(c, tuckˑvˑletter);
            scope(exit) rt.tuckDrop(tuckˑvˑspecˑ1);
            if (!(tuckˑvˑspecˑ1.status == rt.TuckStatus.Ok)) {
                return rt.tnone!(tuckˑtypeˑArgs)();
            }
            if (tuckˑfnˑisFlag(tuckˑvˑspecˑ1.value)) {
                tuckˑvˑa = tuckˑfnˑwithEntry_moved(tuckˑvˑa, (tuckˑvˑspecˑ1.value.name).idup, ("true").idup);
            } else {
                if ((tuckˑvˑi >= cast(long) argv.length)) {
                    return rt.tnone!(tuckˑtypeˑArgs)();
                }
                string tuckˑvˑvalueˑ2 = (rt.tuckAt(argv, tuckˑvˑi)).idup;
                scope(exit) rt.tuckDrop(tuckˑvˑvalueˑ2);
                tuckˑvˑi = (tuckˑvˑi + 1L);
                if (!tuckˑfnˑaccepts(tuckˑvˑspecˑ1.value, tuckˑvˑvalueˑ2)) {
                    return rt.tnone!(tuckˑtypeˑArgs)();
                }
                tuckˑvˑa = tuckˑfnˑwithEntry_moved(tuckˑvˑa, (tuckˑvˑspecˑ1.value.name).idup, tuckˑvˑvalueˑ2);
                tuckˑvˑvalueˑ2 = typeof(tuckˑvˑvalueˑ2).init;
            }
        } else {
            rt.TuckResult!(tuckˑtypeˑCommand) tuckˑvˑsub = tuckˑfnˑsubcommandNamed(c, tuckˑvˑarg);
            scope(exit) rt.tuckDrop(tuckˑvˑsub);
            if ((tuckˑvˑsub.status == rt.TuckStatus.Ok)) {
                if ((cast(long) tuckˑvˑa.positional.length == 0L)) {
                    string[] tuckˑvˑrest = tuckˑfnˑtailFrom_moved(argv, tuckˑvˑi);
                    scope(exit) rt.tuckDrop(tuckˑvˑrest);
                    rt.TuckResult!(tuckˑtypeˑArgs) tuckˑvˑinner = tuckˑfnˑtryParse(tuckˑvˑsub.value, tuckˑvˑrest);
                    scope(exit) rt.tuckDrop(tuckˑvˑinner);
                    if (!(tuckˑvˑinner.status == rt.TuckStatus.Ok)) {
                        return rt.tnone!(tuckˑtypeˑArgs)();
                    }
                    tuckˑtypeˑArgs tuckOwnTmp22 = tuckˑfnˑmerged_moved(tuckˑvˑa, tuckˑvˑinner.value, tuckˑvˑarg);
                    tuckˑvˑarg = typeof(tuckˑvˑarg).init;
                    tuckˑvˑa = typeof(tuckˑvˑa).init;
                    return rt.tok(tuckOwnTmp22);
                }
            }
            tuckˑvˑa = tuckˑfnˑwithPositional_moved(tuckˑvˑa, tuckˑvˑarg);
            tuckˑvˑarg = typeof(tuckˑvˑarg).init;
        }
    }
    if (!tuckˑfnˑrequiredPresent(c, tuckˑvˑa)) {
        return rt.tnone!(tuckˑtypeˑArgs)();
    }
    tuckˑtypeˑArgs tuckOwnTmp23 = tuckˑvˑa;
    tuckˑvˑa = typeof(tuckˑvˑa).init;
    tuckˑtypeˑArgs tuckOwnTmp24 = tuckOwnTmp23;
    tuckˑvˑa.subcommand = typeof(tuckˑvˑa.subcommand).init;
    tuckˑtypeˑArgs tuckOwnTmp25 = tuckOwnTmp24;
    tuckˑvˑa.positional = typeof(tuckˑvˑa.positional).init;
    return rt.tok(tuckOwnTmp25);
}

string[] tuckˑfnˑtailFrom(string[] items, long start) {
    return tuckˑfnˑtailFrom_moved(items, start);
}

string[] tuckˑfnˑtailFrom_moved(string[] items, long start) {
    string[] tuckˑvˑout = [];
    foreach (tuckˑvˑi; start .. (cast(long) items.length - 1L) + 1) {
        rt.tuckPush(tuckˑvˑout, (rt.tuckAt(items, tuckˑvˑi)).idup);
    }
    return tuckˑvˑout;
}

tuckˑtypeˑArgs tuckˑfnˑmerged(tuckˑtypeˑArgs a, tuckˑtypeˑArgs inner, string name) {
    a = rt.tuckCopy(a);
    name = rt.tuckCopy(name);
    return tuckˑfnˑmerged_moved(a, inner, name);
}

tuckˑtypeˑArgs tuckˑfnˑmerged_moved(tuckˑtypeˑArgs a, tuckˑtypeˑArgs inner, string name) {
    scope(exit) rt.tuckDrop(a.subcommand);
    tuckˑtypeˑEntry[] tuckˑvˑvals = a.named;
    foreach (tuckˑvˑi; 0L .. (cast(long) inner.named.length - 1L) + 1) {
        rt.tuckPush(tuckˑvˑvals, rt.tuckCopy(rt.tuckAt(inner.named, tuckˑvˑi)));
    }
    string[] tuckˑvˑpos = a.positional;
    foreach (tuckˑvˑi; 0L .. (cast(long) inner.positional.length - 1L) + 1) {
        rt.tuckPush(tuckˑvˑpos, (rt.tuckAt(inner.positional, tuckˑvˑi)).idup);
    }
    return tuckˑtypeˑArgs(named: tuckˑvˑvals, positional: tuckˑvˑpos, subcommand: name);
}

string tuckˑfnˑflagText(tuckˑtypeˑArgSpec spec) {
    string tuckˑvˑs = ("--" ~ spec.name);
    if ((tuckˑmodˑstr.byteCount(spec.shortName) > 0L)) {
        string tuckOwnTmp26 = (tuckˑvˑs ~ ", -");
        scope(exit) rt.tuckDrop(tuckOwnTmp26);
        rt.tuckReplace(tuckˑvˑs, (tuckOwnTmp26 ~ spec.shortName));
    }
    return tuckˑvˑs;
}

string tuckˑfnˑusageOf(tuckˑtypeˑCommand c) {
    string[] tuckˑvˑlines = [];
    scope(exit) rt.tuckDrop(tuckˑvˑlines);
    string tuckOwnTmp27 = (c.name ~ " - ");
    scope(exit) rt.tuckDrop(tuckOwnTmp27);
    rt.tuckPush(tuckˑvˑlines, (tuckOwnTmp27 ~ c.help));
    foreach (tuckˑvˑi; 0L .. (cast(long) c.args.length - 1L) + 1) {
        tuckˑtypeˑArgSpec tuckˑvˑspec = rt.tuckCopy(rt.tuckAt(c.args, tuckˑvˑi));
        scope(exit) rt.tuckDrop(tuckˑvˑspec.name);
        scope(exit) rt.tuckDrop(tuckˑvˑspec.help);
        scope(exit) rt.tuckDrop(tuckˑvˑspec.shortName);
        string tuckˑvˑflag = tuckˑfnˑflagText(tuckˑvˑspec);
        string tuckˑvˑleft = tuckˑmodˑfmt.tuckˑfnˑpad(tuckˑvˑflag, 18L, false);
        scope(exit) rt.tuckDrop(tuckˑvˑleft);
        string tuckOwnTmp28 = ("  " ~ tuckˑvˑleft);
        scope(exit) rt.tuckDrop(tuckOwnTmp28);
        string tuckˑvˑline = (tuckOwnTmp28 ~ tuckˑvˑspec.help);
        if (tuckˑvˑspec.required) {
            rt.tuckStrAppend(tuckˑvˑline, " (required)");
        }
        rt.tuckPush(tuckˑvˑlines, tuckˑvˑline);
    }
    foreach (tuckˑvˑi; 0L .. (cast(long) c.subcommands.length - 1L) + 1) {
        tuckˑtypeˑCommand tuckˑvˑsub = rt.tuckCopy(rt.tuckAt(c.subcommands, tuckˑvˑi));
        scope(exit) rt.tuckDrop(tuckˑvˑsub.args);
        scope(exit) rt.tuckDrop(tuckˑvˑsub.subcommands);
        scope(exit) rt.tuckDrop(tuckˑvˑsub.help);
        string tuckˑvˑleftˑ1 = tuckˑmodˑfmt.tuckˑfnˑpad(tuckˑvˑsub.name, 18L, false);
        scope(exit) rt.tuckDrop(tuckˑvˑleftˑ1);
        string tuckOwnTmp29 = ("  " ~ tuckˑvˑleftˑ1);
        scope(exit) rt.tuckDrop(tuckOwnTmp29);
        rt.tuckPush(tuckˑvˑlines, (tuckOwnTmp29 ~ tuckˑvˑsub.help));
    }
    return tuckˑmodˑstr.joinStr(tuckˑvˑlines, "\n");
}

long tuckˑfnˑwidthOf(long column, string[] headers, string[][] rows) {
    long tuckˑvˑw = tuckˑmodˑstr.byteCount(rt.tuckAt(headers, column));
    foreach (tuckˑvˑr; 0L .. (cast(long) rows.length - 1L) + 1) {
        long tuckˑvˑn = tuckˑmodˑstr.byteCount(rt.tuckAt(rt.tuckAt(rows, tuckˑvˑr), column));
        if ((tuckˑvˑn > tuckˑvˑw)) {
            tuckˑvˑw = tuckˑvˑn;
        }
    }
    return tuckˑvˑw;
}

string tuckˑfnˑdashes(long count) {
    string tuckˑvˑout = ("").idup;
    foreach (tuckˑvˑi; 0L .. (count - 1L) + 1) {
        rt.tuckStrAppend(tuckˑvˑout, "-");
    }
    return tuckˑvˑout;
}

string tuckˑfnˑrenderRow(string[] cells, long[] widths) {
    string[] tuckˑvˑparts = [];
    scope(exit) rt.tuckDrop(tuckˑvˑparts);
    foreach (tuckˑvˑi; 0L .. (cast(long) cells.length - 1L) + 1) {
        string tuckˑvˑcell = (rt.tuckAt(cells, tuckˑvˑi)).idup;
        if ((tuckˑvˑi < (cast(long) cells.length - 1L))) {
            rt.tuckReplace(tuckˑvˑcell, tuckˑmodˑfmt.tuckˑfnˑpad((rt.tuckAt(cells, tuckˑvˑi)).idup, rt.tuckAt(widths, tuckˑvˑi), false));
        }
        rt.tuckPush(tuckˑvˑparts, tuckˑvˑcell);
    }
    return tuckˑmodˑstr.joinStr(tuckˑvˑparts, " | ");
}

string tuckˑfnˑrenderTable(string[] headers, string[][] rows) {
    long[] tuckˑvˑwidths = [];
    scope(exit) rt.tuckDrop(tuckˑvˑwidths);
    foreach (tuckˑvˑc; 0L .. (cast(long) headers.length - 1L) + 1) {
        long tuckˑvˑw = tuckˑfnˑwidthOf(tuckˑvˑc, headers, rows);
        rt.tuckPush(tuckˑvˑwidths, tuckˑvˑw);
    }
    string[] tuckˑvˑlines = [];
    scope(exit) rt.tuckDrop(tuckˑvˑlines);
    string tuckˑvˑhead = tuckˑfnˑrenderRow(headers, tuckˑvˑwidths);
    rt.tuckPush(tuckˑvˑlines, tuckˑvˑhead);
    string[] tuckˑvˑrule = [];
    scope(exit) rt.tuckDrop(tuckˑvˑrule);
    foreach (tuckˑvˑc; 0L .. (cast(long) tuckˑvˑwidths.length - 1L) + 1) {
        string tuckˑvˑrun = tuckˑfnˑdashes(rt.tuckAt(tuckˑvˑwidths, tuckˑvˑc));
        rt.tuckPush(tuckˑvˑrule, tuckˑvˑrun);
    }
    string tuckˑvˑruleLine = tuckˑmodˑstr.joinStr(tuckˑvˑrule, " | ");
    rt.tuckPush(tuckˑvˑlines, tuckˑvˑruleLine);
    foreach (tuckˑvˑr; 0L .. (cast(long) rows.length - 1L) + 1) {
        string tuckˑvˑline = tuckˑfnˑrenderRow(rt.tuckAt(rows, tuckˑvˑr), tuckˑvˑwidths);
        rt.tuckPush(tuckˑvˑlines, tuckˑvˑline);
    }
    return tuckˑmodˑstr.joinStr(tuckˑvˑlines, "\n");
}

string tuckˑfnˑescapeByte() {
    ubyte[] tuckˑvˑb = [];
    scope(exit) rt.tuckDrop(tuckˑvˑb);
    rt.tuckPush(tuckˑvˑb, cast(ubyte)27);
    return tuckˑmodˑstr.fromBytes(tuckˑvˑb);
}

string tuckˑfnˑcolourCode(tuckˑtypeˑColour colour) {
    final switch (colour) {
    case tuckˑtypeˑColour.Plain:
        return ("").idup;
    case tuckˑtypeˑColour.Red:
        return ("31").idup;
    case tuckˑtypeˑColour.Green:
        return ("32").idup;
    case tuckˑtypeˑColour.Yellow:
        return ("33").idup;
    case tuckˑtypeˑColour.Blue:
        return ("34").idup;
    }
    return typeof(return).init;
}

string tuckˑfnˑstyled(string body, tuckˑtypeˑColour colour, bool bold) {
    scope(exit) rt.tuckDrop(body);
    string tuckˑvˑcode = tuckˑfnˑcolourCode(colour);
    scope(exit) rt.tuckDrop(tuckˑvˑcode);
    if (((tuckˑvˑcode == "") && !bold)) {
        string tuckOwnTmp35 = body;
        body = typeof(body).init;
        return tuckOwnTmp35;
    }
    string tuckˑvˑattrs = (tuckˑvˑcode).idup;
    scope(exit) rt.tuckDrop(tuckˑvˑattrs);
    if (bold) {
        rt.tuckReplace(tuckˑvˑattrs, ("1").idup);
        if ((tuckˑvˑcode != "")) {
            rt.tuckReplace(tuckˑvˑattrs, ("1;" ~ tuckˑvˑcode));
        }
    }
    string tuckˑvˑesc = tuckˑfnˑescapeByte();
    scope(exit) rt.tuckDrop(tuckˑvˑesc);
    string tuckOwnTmp30 = (tuckˑvˑesc ~ "[");
    scope(exit) rt.tuckDrop(tuckOwnTmp30);
    string tuckOwnTmp31 = (tuckOwnTmp30 ~ tuckˑvˑattrs);
    scope(exit) rt.tuckDrop(tuckOwnTmp31);
    string tuckOwnTmp32 = (tuckOwnTmp31 ~ "m");
    scope(exit) rt.tuckDrop(tuckOwnTmp32);
    string tuckOwnTmp33 = (tuckOwnTmp32 ~ body);
    scope(exit) rt.tuckDrop(tuckOwnTmp33);
    string tuckOwnTmp34 = (tuckOwnTmp33 ~ tuckˑvˑesc);
    scope(exit) rt.tuckDrop(tuckOwnTmp34);
    return (tuckOwnTmp34 ~ "[0m");
}

tuckˑtypeˑArgSpec tuckˑfnˑspec(string name, string shortName, tuckˑtypeˑArgKind kind, string help, bool required) {
    return tuckˑtypeˑArgSpec(name: name, shortName: shortName, kind: kind, help: help, required: required);
}

tuckˑtypeˑCommand tuckˑfnˑdemo() {
    tuckˑtypeˑArgSpec[] tuckˑvˑargs = [];
    tuckˑtypeˑArgSpec tuckˑvˑverbose = tuckˑfnˑspec(("verbose").idup, ("v").idup, tuckˑtypeˑArgKind.AFlag, ("chatty").idup, false);
    tuckˑtypeˑArgSpec tuckˑvˑname = tuckˑfnˑspec(("name").idup, ("n").idup, tuckˑtypeˑArgKind.AText, ("who").idup, true);
    tuckˑtypeˑArgSpec tuckˑvˑcount = tuckˑfnˑspec(("count").idup, ("c").idup, tuckˑtypeˑArgKind.ANumber, ("how many").idup, false);
    rt.tuckPush(tuckˑvˑargs, tuckˑvˑverbose);
    rt.tuckPush(tuckˑvˑargs, tuckˑvˑname);
    rt.tuckPush(tuckˑvˑargs, tuckˑvˑcount);
    tuckˑtypeˑCommand[] tuckˑvˑsubs = [];
    tuckˑtypeˑArgSpec[] tuckˑvˑnoargs = [];
    tuckˑtypeˑCommand[] tuckˑvˑnosubs = [];
    tuckˑtypeˑCommand tuckˑvˑbuild = tuckˑtypeˑCommand(name: ("build").idup, help: ("make it").idup, args: tuckˑvˑnoargs, subcommands: tuckˑvˑnosubs);
    rt.tuckPush(tuckˑvˑsubs, tuckˑvˑbuild);
    return tuckˑtypeˑCommand(name: ("app").idup, help: ("a demo").idup, args: tuckˑvˑargs, subcommands: tuckˑvˑsubs);
}

long tuckˑfnˑcheckParsing() {
    tuckˑtypeˑCommand tuckˑvˑc = tuckˑfnˑdemo();
    scope(exit) rt.tuckDrop(tuckˑvˑc.name);
    scope(exit) rt.tuckDrop(tuckˑvˑc.subcommands);
    scope(exit) rt.tuckDrop(tuckˑvˑc.help);
    scope(exit) rt.tuckDrop(tuckˑvˑc.args);
    string[] tuckˑvˑargv = [("--name").idup, ("bob").idup, ("-v").idup, ("--count=3").idup, ("extra").idup];
    scope(exit) rt.tuckDrop(tuckˑvˑargv);
    rt.TuckResult!(tuckˑtypeˑArgs) tuckˑvˑa = tuckˑfnˑtryParse(tuckˑvˑc, tuckˑvˑargv);
    scope(exit) rt.tuckDrop(tuckˑvˑa);
    if (!(tuckˑvˑa.status == rt.TuckStatus.Ok)) {
        return 1L;
    }
    rt.TuckResult!(string) tuckˑvˑwho = tuckˑfnˑtextOf(tuckˑvˑa.value, "name");
    scope(exit) rt.tuckDrop(tuckˑvˑwho);
    if (!(tuckˑvˑwho.status == rt.TuckStatus.Ok)) {
        return 2L;
    }
    if ((tuckˑvˑwho.value != "bob")) {
        return 2L;
    }
    if (!tuckˑfnˑhasFlag(tuckˑvˑa.value, "verbose")) {
        return 3L;
    }
    rt.TuckResult!(long) tuckˑvˑn = tuckˑfnˑnumberOf(tuckˑvˑa.value, "count");
    if (!(tuckˑvˑn.status == rt.TuckStatus.Ok)) {
        return 4L;
    }
    if ((tuckˑvˑn.value != 3L)) {
        return 4L;
    }
    if (((cast(long) tuckˑvˑa.value.positional.length != 1L) || (rt.tuckAt(tuckˑvˑa.value.positional, 0L) != "extra"))) {
        return 5L;
    }
    return tuckˑfnˑcheckRefusals();
}

long tuckˑfnˑcheckRefusals() {
    tuckˑtypeˑCommand tuckˑvˑc = tuckˑfnˑdemo();
    scope(exit) rt.tuckDrop(tuckˑvˑc.name);
    scope(exit) rt.tuckDrop(tuckˑvˑc.subcommands);
    scope(exit) rt.tuckDrop(tuckˑvˑc.help);
    scope(exit) rt.tuckDrop(tuckˑvˑc.args);
    string[] tuckˑvˑnoName = [("-v").idup];
    scope(exit) rt.tuckDrop(tuckˑvˑnoName);
    rt.TuckResult!(tuckˑtypeˑArgs) tuckˑvˑr1 = tuckˑfnˑtryParse(tuckˑvˑc, tuckˑvˑnoName);
    scope(exit) rt.tuckDrop(tuckˑvˑr1);
    if ((tuckˑvˑr1.status == rt.TuckStatus.Ok)) {
        return 6L;
    }
    string[] tuckˑvˑunknown = [("--name").idup, ("x").idup, ("--bogus").idup];
    scope(exit) rt.tuckDrop(tuckˑvˑunknown);
    rt.TuckResult!(tuckˑtypeˑArgs) tuckˑvˑr2 = tuckˑfnˑtryParse(tuckˑvˑc, tuckˑvˑunknown);
    scope(exit) rt.tuckDrop(tuckˑvˑr2);
    if ((tuckˑvˑr2.status == rt.TuckStatus.Ok)) {
        return 7L;
    }
    string[] tuckˑvˑbadNumber = [("--name").idup, ("x").idup, ("--count").idup, ("many").idup];
    scope(exit) rt.tuckDrop(tuckˑvˑbadNumber);
    rt.TuckResult!(tuckˑtypeˑArgs) tuckˑvˑr3 = tuckˑfnˑtryParse(tuckˑvˑc, tuckˑvˑbadNumber);
    scope(exit) rt.tuckDrop(tuckˑvˑr3);
    if ((tuckˑvˑr3.status == rt.TuckStatus.Ok)) {
        return 8L;
    }
    string[] tuckˑvˑdangling = [("--name").idup];
    scope(exit) rt.tuckDrop(tuckˑvˑdangling);
    rt.TuckResult!(tuckˑtypeˑArgs) tuckˑvˑr4 = tuckˑfnˑtryParse(tuckˑvˑc, tuckˑvˑdangling);
    scope(exit) rt.tuckDrop(tuckˑvˑr4);
    if ((tuckˑvˑr4.status == rt.TuckStatus.Ok)) {
        return 9L;
    }
    return tuckˑfnˑcheckSubcommand();
}

long tuckˑfnˑcheckSubcommand() {
    tuckˑtypeˑCommand tuckˑvˑc = tuckˑfnˑdemo();
    scope(exit) rt.tuckDrop(tuckˑvˑc.name);
    scope(exit) rt.tuckDrop(tuckˑvˑc.subcommands);
    scope(exit) rt.tuckDrop(tuckˑvˑc.help);
    scope(exit) rt.tuckDrop(tuckˑvˑc.args);
    string[] tuckˑvˑargv = [("--name").idup, ("bob").idup, ("build").idup];
    scope(exit) rt.tuckDrop(tuckˑvˑargv);
    rt.TuckResult!(tuckˑtypeˑArgs) tuckˑvˑa = tuckˑfnˑtryParse(tuckˑvˑc, tuckˑvˑargv);
    scope(exit) rt.tuckDrop(tuckˑvˑa);
    if (!(tuckˑvˑa.status == rt.TuckStatus.Ok)) {
        return 10L;
    }
    if ((tuckˑvˑa.value.subcommand != "build")) {
        return 11L;
    }
    return tuckˑfnˑcheckOutput();
}

long tuckˑfnˑcheckOutput() {
    tuckˑtypeˑCommand tuckˑvˑc = tuckˑfnˑdemo();
    scope(exit) rt.tuckDrop(tuckˑvˑc.name);
    scope(exit) rt.tuckDrop(tuckˑvˑc.subcommands);
    scope(exit) rt.tuckDrop(tuckˑvˑc.help);
    scope(exit) rt.tuckDrop(tuckˑvˑc.args);
    string tuckˑvˑusage = tuckˑfnˑusageOf(tuckˑvˑc);
    scope(exit) rt.tuckDrop(tuckˑvˑusage);
    if (!tuckˑmodˑtext.tuckˑfnˑstartsWith(tuckˑvˑusage, "app - a demo")) {
        return 12L;
    }
    if (!tuckˑmodˑtext.tuckˑfnˑhas(tuckˑvˑusage, "--verbose, -v")) {
        return 13L;
    }
    if (!tuckˑmodˑtext.tuckˑfnˑhas(tuckˑvˑusage, "(required)")) {
        return 14L;
    }
    string[] tuckˑvˑheaders = [("id").idup, ("name").idup];
    scope(exit) rt.tuckDrop(tuckˑvˑheaders);
    string[] tuckˑvˑrow1 = [("1").idup, ("alpha").idup];
    string[] tuckˑvˑrow2 = [("22").idup, ("b").idup];
    string[][] tuckˑvˑrows = [];
    scope(exit) rt.tuckDrop(tuckˑvˑrows);
    rt.tuckPush(tuckˑvˑrows, tuckˑvˑrow1);
    rt.tuckPush(tuckˑvˑrows, tuckˑvˑrow2);
    string tuckˑvˑtable = tuckˑfnˑrenderTable(tuckˑvˑheaders, tuckˑvˑrows);
    scope(exit) rt.tuckDrop(tuckˑvˑtable);
    string tuckˑvˑwant = ("id | name\n-- | -----\n1  | alpha\n22 | b").idup;
    scope(exit) rt.tuckDrop(tuckˑvˑwant);
    if ((tuckˑvˑtable != tuckˑvˑwant)) {
        return 15L;
    }
    string tuckˑvˑplain = tuckˑfnˑstyled(("x").idup, tuckˑtypeˑColour.Plain, false);
    scope(exit) rt.tuckDrop(tuckˑvˑplain);
    if ((tuckˑvˑplain != "x")) {
        return 16L;
    }
    string tuckˑvˑred = tuckˑfnˑstyled(("x").idup, tuckˑtypeˑColour.Red, true);
    scope(exit) rt.tuckDrop(tuckˑvˑred);
    if ((cast(long) tuckˑvˑred.length != 12L)) {
        return 17L;
    }
    return 0L;
}

long tuckˑfnˑmain() {
    return tuckˑfnˑcheckParsing();
}

