{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc `==`*(a, b: tuck_PodcastPlayerLifecycle): bool {.noSideEffect.}

type tuck_Config* = object
  url*: string

type tuck_Feed* = object
  title*: string

type tuck_PodcastPlayerLifecycleKind* = enum Unloaded, Loading, Ready
type tuck_PodcastPlayerLifecycle* = object
  case kind*: tuck_PodcastPlayerLifecycleKind
  of Unloaded: tuck_unloaded*: tuple[config: tuck_Config]
  of Loading: tuck_loading*: tuple[config: tuck_Config, progress: int]
  of Ready: tuck_ready*: tuple[config: tuck_Config, feed: tuck_Feed]

proc `==`*(a, b: tuck_PodcastPlayerLifecycle): bool {.noSideEffect.} =
  if a.kind != b.kind: return false
  case a.kind
  of Unloaded: a.tuck_unloaded == b.tuck_unloaded
  of Loading: a.tuck_loading == b.tuck_loading
  of Ready: a.tuck_ready == b.tuck_ready
proc canTransition*(frm, to: tuck_PodcastPlayerLifecycleKind): bool =
  case frm
  of Unloaded: to in {Loading}
  of Loading: to in {Ready, Unloaded}
  of Ready: to in {Unloaded}
proc transitionTo*(self: var tuck_PodcastPlayerLifecycle, target: tuck_PodcastPlayerLifecycle) =
  if not canTransition(self.kind, target.kind):
    raise newException(ValueError, "Invalid transition " & $self.kind & " -> " & $target.kind)
  self = target

