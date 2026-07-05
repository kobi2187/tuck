# Tuck Tutorial

This tutorial shows the core Tuck syntax and the intended workflow for writing Tuck code.
It is intentionally small, focused on the language shape rather than implementation details.

## 1. Core idea

Tuck is a postfix / concatenative-inspired language built around one strong rule:

- every function receives exactly one named struct argument

That struct carries the data. If a function needs more than one value, they are grouped into one struct.

## 2. Named structs

A simple value is always a struct with named fields.

```tuck
let request = {url: "example.com", timeout: 5.seconds}
```

The struct can flow through postfix application.

```tuck
let response = request fetch parse episodes
```

## 3. Function signatures

All functions take one named struct argument and must declare a return type.

```tuck
fn classify({celsius: f32}) -> {state: ThermalState}:
  ...
```

The one-argument rule keeps the language uniform and avoids positional ambiguity.

## 4. Builder vs regular chaining

Tuck distinguishes two kinds of chaining:

- `..` — builder / mutation style. Returns `self` so you can continue mutating.
- implicit whitespace — regular functional invocation. Passes the previous struct into the next function.

Example:

```tuck
var server = ServerConfig {}
server ..port {8080} ..timeout {30.seconds} ..start
```

Use whitespace when the next step is a pure or terminal operation.

## 5. Objects and composition

Use `type` for plain data and `object` for composition, mixins, and app assembly.

```tuck
type Episode:
  title: str
  duration: u32

object PodcastApp:
  host: str
  library: Seq[Episode]
```

Objects are the main place where multiple pieces of state and behavior are combined.

## 6. The special `input` keyword

Inside function bodies, `input` is a reserved name that refers to the full incoming argument struct.

```tuck
fn changePlaySpeed({app: PodcastApp, ratio: float}) -> PodcastApp:
  for x in input.app.library:
    x.playSpeed = ratio
  return app
```

That means:

- `input` is not a field name
- it always points to the payload struct for the current function
- you do not destructure it unless you want to

## 7. Explicit one-argument payloads

When you need app state plus a request, keep them in one struct.

```tuck
fn play({app: PodcastApp, episode: Episode}) -> void:
  let ctx = {app, episode} merge
  ctx ..loadEpisode startAudio
```

This keeps the function signature uniform and easy to refactor.

## 8. Pure concatenative module calls

If you want the pure postfix concatenative style, put the payload first and the function reference second.

```tuck
{episode: episode, source: app} audio::play
```

That reads as:

- take the payload struct
- then call the imported function `audio::play`

## 9. Events and registry

Tuck supports one global registry for app-wide signals.

```tuck
registry AppEvents:
  | SensorFailure({port: u8, reason: str})

AppEvents.raise SensorFailure {port: 1, reason: "timeout"}
```

If you adopt `upon` for handlers, the handler syntax can be written as:

```tuck
upon AppEvents.SensorFailure({port, reason}):
  log.warn "sensor {port} failed"
```

## 10. Summary of conventions

- `type` = plain data / sums
- `object` = composition / app assembly
- one named struct argument per function
- `!` = explicit failure syntax, valid only when `[io]` is present or inferred
- `..` = builder / mutate self
- whitespace = regular invocation
- `.` = field/member access
- `input` = incoming payload tuple
- `audio::play` = postfix module function call

## 11. Example flow

```tuck
type Episode:
  title: str
  duration: u32

object PodcastApp:
  host: str
  library: Seq[Episode]

fn play({app: PodcastApp, episode: Episode}) -> void:
  let ctx = {app, episode} merge
  ctx ..loadEpisode startAudio

fn loadEpisode({app: PodcastApp, episode: Episode}) -> PodcastApp:
  app ..currentEpisode {episode} ..lastPlayed {episode.title}

fn startAudio({app: PodcastApp, episode: Episode}) -> void:
  {episode: episode, source: app} audio::play
```

That covers the main shape of Tuck programs and shows how state, input, and modular calls flow together.
