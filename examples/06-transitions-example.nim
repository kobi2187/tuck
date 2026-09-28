{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc `==`*(a, b: tuckˑtypeˑPodcastPlayerLifecycle): bool {.noSideEffect.}

type tuckˑtypeˑConfig* = object
  url*: string

type tuckˑtypeˑFeed* = object
  title*: string

type tuckˑtypeˑPodcastPlayerLifecycleKind* = enum Unloaded, Loading, Ready
type tuckˑtypeˑPodcastPlayerLifecycle* = object
  case kind*: tuckˑtypeˑPodcastPlayerLifecycleKind
  of Unloaded: tuckˑvariantˑunloaded*: tuple[config: tuckˑtypeˑConfig]
  of Loading: tuckˑvariantˑloading*: tuple[config: tuckˑtypeˑConfig, progress: int]
  of Ready: tuckˑvariantˑready*: tuple[config: tuckˑtypeˑConfig, feed: tuckˑtypeˑFeed]

proc `==`*(a, b: tuckˑtypeˑPodcastPlayerLifecycle): bool {.noSideEffect.} =
  if a.kind != b.kind: return false
  case a.kind
  of Unloaded: a.tuckˑvariantˑunloaded == b.tuckˑvariantˑunloaded
  of Loading: a.tuckˑvariantˑloading == b.tuckˑvariantˑloading
  of Ready: a.tuckˑvariantˑready == b.tuckˑvariantˑready
proc canTransition*(frm, to: tuckˑtypeˑPodcastPlayerLifecycleKind): bool =
  case frm
  of Unloaded: to in {Loading}
  of Loading: to in {Ready, Unloaded}
  of Ready: to in {Unloaded}
proc transitionTo*(self: var tuckˑtypeˑPodcastPlayerLifecycle, target: tuckˑtypeˑPodcastPlayerLifecycle) =
  if not canTransition(self.kind, target.kind):
    raise newException(ValueError, "Invalid transition " & $self.kind & " -> " & $target.kind)
  self = target

