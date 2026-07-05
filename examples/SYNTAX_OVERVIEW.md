# Tuck Syntax Example Files

This directory contains short example files that showcase key Tuck syntax patterns and help you choose the language shape before committing to parsing rules.

## Files

- `01-data-flow.tuck` — basic named structs and postfix flow with conditional branches.
- `02-builder-mutation.tuck` — mutation/builder syntax using `..`.
- `03-functions-bake.tuck` — higher-order function fields and `bake` field updates.
- `04-sum-types-interface.tuck` — sum types, interfaces, mixins, and object composition.
- `05-actors-effects.tuck` — actor syntax, effect markers, and `pending` stubs.
- `06-transitions-example.tuck` — ADT transitions and state-machine-safe lifecycle declarations.
- `07-comments.tuck` — hash-style comments and inline comment placement.
- `17-input-merge.tuck` — `input` as a reserved incoming tuple plus pure postfix module calls with `audio::play`.
- `18-alias.tuck` — explicit field renaming with `alias(...)` for chain compatibility.

## How to run the lexer examples

Use the test harness in `tests/lexer_examples.nim` to tokenize each example and inspect the token stream.

```bash
nim compile --run tests/lexer_examples.nim
```

That harness is intentionally small so you can focus on syntax examples while keeping the lexer simple.
