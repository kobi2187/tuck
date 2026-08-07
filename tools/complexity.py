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

# A proc's body ends at the next proc OR at any other top-level construct.
# Without this, a trailing `when isMainModule:` block was charged to whatever
# proc happened to precede it — which reported tuck.nim's 9-line checkProgram
# as 184 lines at complexity 50, by far the worst in the codebase and entirely
# an artifact.
TOP_LEVEL = re.compile(r'^(when|if|type|const|let|var|import|from|export|'
                       r'include|macro|using|block|for|while|echo|discard)\b')

MAX_LINES = 8
MAX_COMPLEXITY = 5


def body_end(lines, start):
    """Where the proc beginning at `start` ends.

    A proc's body is its indented lines. It ends at the first later line that
    is in column 0 and is not a continuation of the signature — the next proc,
    a `when` block, a type section, anything at top level.
    """
    for i in range(start + 1, len(lines)):
        line = lines[i]
        if not line.strip() or line[0] in ' \t':
            continue
        if PROC_START.match(line) or TOP_LEVEL.match(line):
            return i
        # a bare top-level identifier line (rare) also closes the body
        if not line.startswith(')') and not line.startswith('#'):
            return i
    return len(lines)


def measure(path):
    """Yield (lines, complexity, lineno, name) for every proc in a file."""
    lines = open(path, encoding='utf-8').read().split('\n')
    for start, line in enumerate(lines):
        if not PROC_START.match(line):
            continue
        name = PROC_NAME.match(line)
        if not name:
            continue
        end = body_end(lines, start)
        body = [l for l in lines[start:end]
                if l.strip() and not l.strip().startswith('#')]
        # A forward declaration has a signature and no body. It is not a proc
        # to measure — the definition further down is.
        if len(body) <= 1 and not lines[start].rstrip().endswith('='):
            continue
        complexity = 1
        for l in lines[start:end]:
            stripped = l.strip()
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
