#!/usr/bin/env python3
"""Rank Nim procs by the two triggers the project refactors on.

  * length  — every proc is 5-8 lines, hard cap ~10 lines of logic
  * cyclomatic complexity — over 5, split unconditionally

There is no Nim tool for this. `nimpretty` only formats, `nimfmt` lints style,
`nim check` has no complexity warning, and the language-agnostic tools (lizard,
scc) cannot parse Nim. Hence this script.

A `case` over an enum is DISPATCH, not complexity, and is fine at any size — so
a one-line `of` arm is not counted as a branch. A multi-line arm is, because at
that point the arm carries logic rather than delegating.

Usage:
    tools/complexity.py compiler/*.nim          # ranked table
    tools/complexity.py --gate 5 compiler/*.nim # exit 1 if any proc exceeds
"""
import re
import sys
import os

PROC_START = re.compile(r'^(proc|func|template|iterator|method|converter) ')
PROC_NAME = re.compile(r'^\w+ ([\w`*]+)')
ONE_LINE_ARM = re.compile(r'^of .*:\s*\S')
BRANCH = re.compile(r'(?<![\w.])(if|elif|while|and|or|except)(?![\w])')

MAX_LINES = 8
MAX_COMPLEXITY = 5


def measure(path):
    """Yield (lines, complexity, lineno, name) for every proc in a file."""
    lines = open(path, encoding='utf-8').read().split('\n')
    starts = [i for i, l in enumerate(lines) if PROC_START.match(l)]
    for idx, start in enumerate(starts):
        end = starts[idx + 1] if idx + 1 < len(starts) else len(lines)
        name = PROC_NAME.match(lines[start])
        if not name:
            continue
        body = [l for l in lines[start:end]
                if l.strip() and not l.strip().startswith('#')]
        complexity = 1
        for line in lines[start:end]:
            stripped = line.strip()
            if stripped.startswith('#') or ONE_LINE_ARM.match(stripped):
                continue
            complexity += len(BRANCH.findall(stripped))
        yield len(body), complexity, start + 1, name.group(1)


def main(argv):
    gate = None
    if argv and argv[0] == '--gate':
        gate = int(argv[1])
        argv = argv[2:]
    if not argv:
        print(__doc__)
        return 2

    rows = []
    for path in argv:
        for n, cc, lineno, name in measure(path):
            rows.append((n, cc, os.path.basename(path), lineno, name))

    over_len = [r for r in rows if r[0] > MAX_LINES]
    over_cc = [r for r in rows if r[1] > MAX_COMPLEXITY]
    print(f'{len(rows)} procs in {len(argv)} files')
    print(f'  over {MAX_LINES} lines : {len(over_len)}')
    print(f'  complexity > {MAX_COMPLEXITY}: {len(over_cc)}')

    if over_cc:
        print()
        print('COMPLEXITY > 5 (split unconditionally):')
        for n, cc, f, lineno, name in sorted(over_cc, key=lambda r: -r[1]):
            print(f'  cc={cc:<3} {n:>3}ln  {f}:{lineno:<5} {name}')

    if gate is not None:
        worst = [r for r in rows if r[1] > gate]
        if worst:
            print(f'\nFAIL: {len(worst)} proc(s) over complexity {gate}')
            return 1
        print(f'\nOK: no proc over complexity {gate}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
