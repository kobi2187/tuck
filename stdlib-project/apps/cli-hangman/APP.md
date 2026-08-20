# App: cli-hangman

A terminal word-guessing game: pick a random secret word from a wordlist, render the ASCII gallows and guessed letters, accept single-letter guesses, track remaining lives, and declare win/lose. Includes a `--practice` mode that logs stats (games played, win rate) to a local file.

## Why this is a good validation target
It is the smallest app in the set on purpose — a control case. If a module's API is *not* pleasant to use even in something this simple, that's a strong signal the API has too much ceremony for its weight class. It's also the primary exercise for `std.random` (non-cryptographic) kept strictly separate from `std.crypto`'s CSPRNG.

## Features
- Load a wordlist file (or built-in default list), pick a word uniformly at random.
- Render gallows state, guessed/missed letters, remaining attempts.
- Input loop: single-character guesses, reject repeats, handle EOF/Ctrl-C cleanly.
- Track and persist simple stats across runs.
- Unit-testable game logic decoupled from terminal rendering (this is itself a validation point for `std.testing`).

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| std | `std.random` | uniform random word selection (explicitly *not* `std.crypto`'s CSPRNG — validates the separation) |
| std | `std.cli` | terminal rendering, colored win/lose banners, key input |
| std | `std.testing` | table-driven tests of pure game-state transitions (guess → new state) |
| sys | `sys.fs` | loading the wordlist, persisting stats |
| alloc | `alloc.string` / `alloc.set` | tracking guessed letters, building the masked-word display |
| core | `core.iter` | iterating letters of the secret word to check completion |
| core | `core.error` | malformed wordlist file, empty input |

## Anticipated API stress points
Almost none at the `core`/`alloc` level — which is itself the finding: a well-designed stdlib should make trivial programs trivial. The one real question it raises is whether `std.testing` makes it easy to test pure logic (the game state machine) in complete isolation from `std.cli`'s I/O, without contorting the production code to inject fakes.
