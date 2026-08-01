#!/bin/bash
# Lexer + parser smoke over every example.
#
# Replaces tests/lexer_examples.nim and tests/parser_examples.nim, which
# printed every token / decl of every example and only actually FAILED when
# the lexer or parser crashed. That is what this checks, without linking the
# compiler into two more Nim programs: `tuck l` and `tuck p` exit nonzero on
# a crash, which is the whole assertion.
#
# Note both verbs are single-FILE (no import resolution), so an example that
# imports a missing module still lexes and parses fine here — resolution is
# tests/examples.sh's job via `tuck ch`.
cd "$(dirname "$0")/.."
. tests/lib.sh

for f in examples/*.tuck; do
  name=$(basename "$f" .tuck)
  if ./tuck l "$f" > /dev/null 2>&1; then _ok "lex   $name"
  else _no "lex   $name" "lexer failed: $(./tuck l "$f" 2>&1 | tail -1)"; fi
done

for f in examples/*.tuck; do
  name=$(basename "$f" .tuck)
  if ./tuck p "$f" > /dev/null 2>&1; then _ok "parse $name"
  else _no "parse $name" "parser failed: $(./tuck p "$f" 2>&1 | tail -1)"; fi
done

finish
