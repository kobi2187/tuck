# fuzz/replay.nim
#
# Reproduce a fuzz finding WITHOUT libFuzzer or the sanitizers.
#
# The harness's own `-d:fuzzStandalone` block cannot be used for this: it
# shares fuzz_frontend.nims, whose --noMain:on and -fsanitize flags are for
# the fuzzer build and break an ordinary one. This is the same replay loop as
# a normal program.
#
#   nim c fuzz/replay.nim
#   ./fuzz/replay fuzz/findings/crash-<hash>
#
# Reports, per input: rejected (with the diagnostic), accepted (with the
# declaration count), or a crash — which is the finding.
import std/[cmdline, syncio, os]
import ../lexer
from ../compiler/modules import lexSource
import ../compiler/[ast, parser, parser_base]


proc replay(path: string) =
  ## Runs the front end on one saved input and prints whether it was accepted,
  ## rejected with a diagnostic, or raised something unexpected.
  let source = readFile(path)
  stdout.write path, " (", source.len, " bytes): "
  try:
    var p = Parser(source: source, tokens: lexSource(source), cursor: 0)
    let m = p.parseModule()
    echo "ACCEPTED — ", m.decls.len, " declaration(s)"
  except SyntaxError as err:
    echo "rejected — ", err.stage, " ", err.line, ":", err.col, " ", err.msg
  except CatchableError as err:
    echo "RAISED ", err.name, " — ", err.msg

when isMainModule:
  if paramCount() == 0:
    echo "usage: replay <input>..."
    quit 2
  for i in 1 .. paramCount():
    replay(paramStr(i))
