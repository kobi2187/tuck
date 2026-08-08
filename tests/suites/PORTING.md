# Porting a tests/*.sh suite to tests/suites/*.nim

Read `tests/harness.nim` first — it is the DSL, ~450 lines, and it answers
most questions. `tests/suites/loop_var_type.nim` and `tests/suites/mangle.nim`
are worked examples: read one before starting.

## The transform

Mechanical. `tests/<name>.sh` becomes `tests/suites/<name>.nim`:

```nim
## <the .sh header comment, verbatim, as ## doc comments>

import ../harness

proc run*(t: var T) =
  t.src """
<the heredoc body, verbatim>
"""
  t.okCheck "case name"
  ...
  t.finish()
```

| bash              | Nim                                     |
|-------------------|-----------------------------------------|
| `src <<'EOF'`     | `t.src """ ... """`                     |
| `ok_check "n"`    | `t.okCheck "n"`                         |
| `bad_check "n" P` | `t.badCheck "n", "P"`                   |
| `runs "n" 2`      | `t.runs "n", 2`                         |
| `outputs "n" P`   | `t.outputs "n", "P"`                    |
| `emits "n" P`     | `t.emits "n", "P"`                      |
| `omits "n" P`     | `t.omits "n", "P"`                      |
| `emits_odin`      | `t.emitsOdin`                           |
| `omits_odin`      | `t.omitsOdin`                           |
| `frozen "n"`      | `t.frozen "n"`                          |
| `try X ; bug_fixed "n"` | `t.quietly: X` then `t.bugFixed "n"` |
| `try X ; bug_open "n"`  | `t.quietly: X` then `t.bugOpen "n"`  |
| `_ok "n"`         | `t.ok "n"`                              |
| `_no "n" "why"`   | `t.no "n", "why"`                       |
| `finish`          | `t.finish()`                            |

## Rules that matter

1. **Keep every comment.** The explanatory comments in these files are the
   most valuable thing in them — they record why a check exists and what bug
   it caught. Port them verbatim as `#` (inside `run`) or `##` (file header).
   Do not summarize, shorten, or "improve" them.

2. **Keep case names byte-identical.** They are the report labels, and
   `frozen` derives its golden filename from the name by slugifying it. A
   changed name means a missing golden.

3. **Patterns are regexes, and Nim strings need the backslash doubled.**
   bash `'tuck_helper\('` becomes `"tuck_helper\\("`. A bare `\(` in a Nim
   string is an error or a wrong pattern. Check every pattern with a
   backslash.

4. **`"""` strings start after the opening quotes.** Write
   `t.src """` then a newline then the code — the leading newline is stripped
   by Nim, matching how a heredoc behaves. Do NOT indent the .tuck source:
   it is whitespace-significant and must stay column-0 exactly as in the
   heredoc.

5. **A snippet containing `"""` cannot go in a `"""` string.** None observed,
   but if you hit one, use a raw string or concatenation and say so in your
   report.

## Two-phase, and what it means for you

A suite body runs TWICE: once to register work, once to report on it. The
assertions handle this themselves — if you only use the table above, you do
not need to think about it.

You DO need to think about it if the .sh does something outside the DSL —
an `if` around a `./tuck` call, a `for` loop over files, a grep of a source
file. Those become:

```nim
  let idx = t.needCmd @["./tuck", "explain", code]   # registers, both passes
  if t.phase == pReport:                             # reads, report pass only
    let (rc, outp) = t.resultOf(idx)
    if rc == 0: t.ok "name" else: t.no "name", outp
```

Anything reading a FILE the pool produced must also be under
`if t.phase == pReport:` — in the collect pass that file does not exist yet.

Registration must happen on BOTH passes and in the SAME ORDER — that is how
the two passes line up. So never put a `needCmd` inside an
`if t.phase == pReport`.

## Verify before reporting done

```bash
cd /home/kl/prog/tuck_lexer
python3 tests/suites/regen.py
nim c --hints:off --warnings:off -o:tests/run tests/runner.nim
./tests/run <name>
```

The verdict line must match the bash original EXACTLY — same passed count,
same failed count, and the same `OPEN`/`open bugs:` lines if any. Your brief
gives you the target number. If it does not match, the port is wrong: fix it,
do not adjust the test to agree with itself.

Cross-check against bash directly when unsure:

```bash
bash tests/<name>.sh
```

Do not edit: `tests/harness.nim`, `tests/runner.nim`, `tests/suites/all.nim`
(generated), any `tests/*.sh`, or any file under `tests/golden/`. If you
believe the harness needs a change, say so in your report instead of making it.
