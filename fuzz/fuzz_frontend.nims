# Build config for the libFuzzer target. Named for the harness, so
# `nim c fuzz/fuzz_frontend.nim` picks it up automatically.
--cc: clang
--panics: on
--define: noSignalHandler
--define: useMalloc
--noMain: on
--passC: "-fsanitize=fuzzer,address,undefined"
--passL: "-fsanitize=fuzzer,address,undefined"
--debugger: native

# The compiler's own switches, which the front end needs to build at all.
# Mirrors the root config.nims — the AST cache unpacks case objects by
# assigning the discriminant after construction.
--define: nimOldCaseObjects
--deepcopy: on

# --panics:on turns a Defect into an immediate process crash, which is what
# makes libFuzzer treat an IndexDefect in the lexer as a finding rather than
# something the harness has to catch.
