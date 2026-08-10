# fuzz/fuzz_frontend.nim
#
# libFuzzer target for the front end: arbitrary bytes -> lexer -> parser.
#
# WHAT THIS CATCHES: a crash. An IndexDefect, an OverflowDefect, a failed
# assert, an unhandled exception, an infinite loop. Anything where malformed
# input takes the compiler down instead of producing a diagnostic.
#
# WHAT THIS DOES NOT CATCH: a MISSING error — invalid source the parser
# happily accepts. Accepting garbage is not a crash, so the fuzzer cannot see
# it. That half is tests/suites/duplicates.nim, which asserts specific inputs ARE
# rejected. Both halves are needed; this one finds the inputs that break the
# machinery, that one finds the inputs the machinery should have refused.
#
# A SyntaxError is the CORRECT outcome for most inputs here, so it is caught
# and discarded. Everything else propagates and crashes the process, which is
# what libFuzzer reports as a finding.
# The PARSER, not modules.nim. modules.nim also does file I/O and msgpack
# cache decoding, whose effects would force this harness to catch far more
# than the front end can actually raise — and a broad catch is what hides
# findings. lexSource/parseSource are duplicated here for that reason; they
# are three lines each.
import ../lexer
import ../compiler/[ast, parser, parser_base]

proc lexAll(source: string): seq[Token] =
  var lex = Lexer(source: source, position: 0, line: 1, column: 1,
                  indentStack: @[0])
  while true:
    let t = lex.nextToken()
    result.add(t)
    if t.kind == tkEOF: break

proc fuzzFrontend(source: string) {.raises: [].} =
  ## Lex and parse, discarding a clean rejection.
  ##
  ## `except Exception` is normally wrong in a fuzz harness — it swallows
  ## Defects and hides the findings. It is safe HERE, and only here, because
  ## this target is built with --panics:on (fuzz_frontend.nims): a Defect
  ## then aborts the process directly rather than unwinding, so no `except`
  ## clause of any breadth can intercept it. An IndexDefect in the lexer still
  ## crashes and libFuzzer still reports it.
  ##
  ## It has to be this broad rather than `except SyntaxError` because Nim's
  ## effect inference puts `Exception` on parseModule — some call in the graph
  ## has an untracked effect. Worth narrowing later; with panics on it costs
  ## the target nothing.
  try:
    var p = Parser(source: source, tokens: lexAll(source), cursor: 0)
    discard p.parseModule()
  except Exception:
    discard          # a rejection: the expected outcome for malformed input

proc initialize(): cint {.exportc: "LLVMFuzzerInitialize".} =
  {.emit: "N_CDECL(void, NimMain)(void); NimMain();".}

proc testOneInput(data: ptr UncheckedArray[byte], len: int): cint {.
    exportc: "LLVMFuzzerTestOneInput", raises: [].} =
  result = 0
  if len == 0:
    fuzzFrontend("")   # the empty file is a real case; do not skip it
    return
  var source = newString(len)
  copyMem(addr source[0], data, len)
  fuzzFrontend(source)

when defined(fuzzStandalone):
  # Replay crash artifacts without linking libFuzzer:
  #   nim c -d:fuzzStandalone fuzz/fuzz_frontend.nim
  #   ./fuzz/fuzz_frontend crash-<hash>
  import std/[cmdline, syncio]
  stderr.write "StandaloneFuzzTarget: running " & $paramCount() & " inputs\n"
  for i in 1 .. paramCount():
    let buf = readFile(paramStr(i))
    stderr.write "  " & paramStr(i) & " (" & $buf.len & " bytes)\n"
    if buf.len == 0:
      discard testOneInput(nil, 0)
    else:
      discard testOneInput(cast[ptr UncheckedArray[byte]](cstring(buf)), buf.len)
  stderr.write "done\n"
