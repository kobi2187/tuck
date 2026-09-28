#!/usr/bin/env python3
"""R11 (ruled 2026-09-28): does every construct cross a module boundary?

Each case in cases.py is a construct declared in `lib` and used from `main`.
It is built and run twice on Nim, Odin and D: as the two modules, and as a
one-module CONTROL (lib pasted above main). A cell reads:

  ok    the two-module program gives the expected exit code
  GAP   the control does and the two-module program does not — a real
        cross-module gap (each one is pinned in tests/suites/cross_module.nim)
  both  the control fails too — the case itself is wrong, not the import

Usage, from the repo root with the toolchains on PATH:
  python3 tools/xmod_scan/scan.py              # every case
  python3 tools/xmod_scan/scan.py mixin pool   # cases whose name contains one
"""
import os, subprocess, shutil, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
from cases import CASES
TUCK = os.path.join(ROOT, "tuck")
BASE = tempfile.mkdtemp(prefix="xmod_scan_")
BACKENDS = [("nim", "", ""), ("odin", "--odin", "_odin"), ("d", "--dlang", "_d")]

def build_run(d, entry, flag, suffix):
    out = os.path.join(d, "out" + suffix)
    p = subprocess.run([TUCK, "b", entry, "-o:" + out, "--root:" + ROOT,
                        "--max-fn-lines:0", "--max-complexity:0"] +
                       ([flag] if flag else []),
                       capture_output=True, text=True, timeout=300)
    if p.returncode != 0:
        text = p.stdout + p.stderr
        lines = [l for l in text.splitlines() if "rror" in l]
        return ("BUILD", (lines[0] if lines else text.strip().splitlines()[-1])[-160:])
    stem = os.path.splitext(os.path.basename(entry))[0]
    try:
        r = subprocess.run([os.path.join(out, stem + suffix)],
                           capture_output=True, text=True, timeout=20)
    except subprocess.TimeoutExpired:
        return ("HANG", "")
    return (r.returncode, "")

only = sys.argv[1:]
for i, c in enumerate(CASES):
    if only and not any(o in c["name"] for o in only):
        continue
    d = os.path.join(BASE, "c%02d" % i)
    ctl = os.path.join(d, "ctl")
    os.makedirs(ctl)
    open(os.path.join(d, "lib.tuck"), "w").write(c["lib"])
    open(os.path.join(d, "main.tuck"), "w").write(c["imports"] + "import lib\n\n" + c["main"])
    open(os.path.join(ctl, "one.tuck"), "w").write(c["imports"] + c["lib"] + "\n" + c["main"])
    line, notes = "%02d %-48s" % (i, c["name"]), []
    for name, flag, suffix in BACKENDS:
        cr = build_run(ctl, os.path.join(ctl, "one.tuck"), flag, suffix)
        xr = build_run(d, os.path.join(d, "main.tuck"), flag, suffix)
        ok_c, ok_x = cr[0] == c["want"], xr[0] == c["want"]
        line += " %s:%s" % (name, "ok" if ok_x else ("GAP" if ok_c else "both"))
        if not ok_x:
            notes.append("     %s: two modules %s %s | control %s %s" %
                         (name, xr[0], xr[1], cr[0], cr[1]))
    print(line, flush=True)
    for n in notes: print(n, flush=True)
shutil.rmtree(BASE, ignore_errors=True)
