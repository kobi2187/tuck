import ../compiler/tuck_rt

type tuck_Config* = object
  url*: string

type tuck_Feed* = object
  title*: string

type tuck_PodcastPlayerLifecycleKind* = enum Unloaded, Loading, Ready
type tuck_PodcastPlayerLifecycle* = object
  case kind*: tuck_PodcastPlayerLifecycleKind
  of Unloaded: unloaded*: tuple[config: tuck_Config]
  of Loading: loading*: tuple[config: tuck_Config, progress: int]
  of Ready: ready*: tuple[config: tuck_Config, feed: tuck_Feed]
proc canTransition*(frm, to: tuck_PodcastPlayerLifecycleKind): bool =
  case frm
  of Unloaded: to in {Loading}
  of Loading: to in {Ready, Unloaded}
  of Ready: to in {Unloaded}
proc transitionTo*(self: var tuck_PodcastPlayerLifecycle, target: tuck_PodcastPlayerLifecycle) =
  if not canTransition(self.kind, target.kind):
    raise newException(ValueError, "Invalid transition " & $self.kind & " -> " & $target.kind)
  self = target

