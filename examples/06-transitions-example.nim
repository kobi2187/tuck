{.experimental: "codeReordering".}
import "../compiler/tuck_rt"

proc `==`*(a, b: tuckˑtypeˑPodcastPlayerLifecycle): bool {.noSideEffect.}
proc tuckDrop*(x: var tuckˑtypeˑPodcastPlayerLifecycle)

type tuckˑtypeˑConfig* = object
  url*: string

type tuckˑtypeˑFeed* = object
  title*: string

type
  tuckˑtypeˑPodcastPlayerLifecycleKind* = enum Unloaded, Loading, Ready
  tuckˑtypeˑPodcastPlayerLifecycle_Unloaded* = object
    config*: tuckˑtypeˑConfig
  tuckˑtypeˑPodcastPlayerLifecycle_Loading* = object
    config*: tuckˑtypeˑConfig
    progress*: int
  tuckˑtypeˑPodcastPlayerLifecycle_Ready* = object
    config*: tuckˑtypeˑConfig
    feed*: tuckˑtypeˑFeed
  tuckˑtypeˑPodcastPlayerLifecycle* = object
    case kind*: tuckˑtypeˑPodcastPlayerLifecycleKind
    of Unloaded: tuckˑvariantˑunloaded*: tuckˑtypeˑPodcastPlayerLifecycle_Unloaded
    of Loading: tuckˑvariantˑloading*: tuckˑtypeˑPodcastPlayerLifecycle_Loading
    of Ready: tuckˑvariantˑready*: tuckˑtypeˑPodcastPlayerLifecycle_Ready

proc `==`*(a, b: tuckˑtypeˑPodcastPlayerLifecycle): bool {.noSideEffect.} =
  if a.kind != b.kind: return false
  case a.kind
  of Unloaded: a.tuckˑvariantˑunloaded == b.tuckˑvariantˑunloaded
  of Loading: a.tuckˑvariantˑloading == b.tuckˑvariantˑloading
  of Ready: a.tuckˑvariantˑready == b.tuckˑvariantˑready

proc tuckDrop*(x: var tuckˑtypeˑPodcastPlayerLifecycle) =
  case x.kind
  of Unloaded: tuckDrop(x.tuckˑvariantˑunloaded)
  of Loading: tuckDrop(x.tuckˑvariantˑloading)
  of Ready: tuckDrop(x.tuckˑvariantˑready)
proc canTransition*(frm, to: tuckˑtypeˑPodcastPlayerLifecycleKind): bool =
  case frm
  of Unloaded: to in {Loading}
  of Loading: to in {Ready, Unloaded}
  of Ready: to in {Unloaded}
proc transitionTo*(self: var tuckˑtypeˑPodcastPlayerLifecycle, target: tuckˑtypeˑPodcastPlayerLifecycle) =
  if not canTransition(self.kind, target.kind):
    raise newException(ValueError, "Invalid transition " & $self.kind & " -> " & $target.kind)
  self = target

