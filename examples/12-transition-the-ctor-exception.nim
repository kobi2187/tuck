{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc `==`*(a, b: tuckˑtypeˑPlayerState): bool {.noSideEffect.}
proc `==`*(a, b: tuckˑtypeˑMqttSession): bool {.noSideEffect.}

proc tuckˑfnˑmain*(): void

type tuckˑtypeˑConfig* = object
  url*: string

type tuckˑtypeˑFeed* = object
  title*: string

type tuckˑtypeˑSocket* = object
  fd*: int

type tuckˑtypeˑPlayerStateKind* = enum Unloaded, Loading, Ready
type tuckˑtypeˑPlayerState* = object
  case kind*: tuckˑtypeˑPlayerStateKind
  of Unloaded: tuckˑvariantˑunloaded*: tuple[config: tuckˑtypeˑConfig]
  of Loading: tuckˑvariantˑloading*: tuple[config: tuckˑtypeˑConfig, progress: int]
  of Ready: tuckˑvariantˑready*: tuple[config: tuckˑtypeˑConfig, feed: tuckˑtypeˑFeed]

proc `==`*(a, b: tuckˑtypeˑPlayerState): bool {.noSideEffect.} =
  if a.kind != b.kind: return false
  case a.kind
  of Unloaded: a.tuckˑvariantˑunloaded == b.tuckˑvariantˑunloaded
  of Loading: a.tuckˑvariantˑloading == b.tuckˑvariantˑloading
  of Ready: a.tuckˑvariantˑready == b.tuckˑvariantˑready
proc canTransition*(frm, to: tuckˑtypeˑPlayerStateKind): bool =
  case frm
  of Unloaded: to in {Loading}
  of Loading: to in {Ready, Unloaded}
  of Ready: false
proc transitionTo*(self: var tuckˑtypeˑPlayerState, target: tuckˑtypeˑPlayerState) =
  if not canTransition(self.kind, target.kind):
    raise newException(ValueError, "Invalid transition " & $self.kind & " -> " & $target.kind)
  self = target

type tuckˑtypeˑMqttSessionKind* = enum Disconnected, Connecting, Connected, Subscribing
type tuckˑtypeˑMqttSession* = object
  case kind*: tuckˑtypeˑMqttSessionKind
  of Disconnected: discard
  of Connecting: tuckˑvariantˑconnecting*: tuple[host: string, port: uint16]
  of Connected: tuckˑvariantˑconnected*: tuple[socket: tuckˑtypeˑSocket, keepalive: uint16]
  of Subscribing: tuckˑvariantˑsubscribing*: tuple[socket: tuckˑtypeˑSocket, topic: string]

proc `==`*(a, b: tuckˑtypeˑMqttSession): bool {.noSideEffect.} =
  if a.kind != b.kind: return false
  case a.kind
  of Disconnected: true
  of Connecting: a.tuckˑvariantˑconnecting == b.tuckˑvariantˑconnecting
  of Connected: a.tuckˑvariantˑconnected == b.tuckˑvariantˑconnected
  of Subscribing: a.tuckˑvariantˑsubscribing == b.tuckˑvariantˑsubscribing
proc canTransition*(frm, to: tuckˑtypeˑMqttSessionKind): bool =
  case frm
  of Disconnected: to in {Connecting}
  of Connecting: to in {Connected, Disconnected}
  of Connected: to in {Subscribing}
  of Subscribing: to in {Connected}
proc transitionTo*(self: var tuckˑtypeˑMqttSession, target: tuckˑtypeˑMqttSession) =
  if not canTransition(self.kind, target.kind):
    raise newException(ValueError, "Invalid transition " & $self.kind & " -> " & $target.kind)
  self = target

proc tuckˑfnˑmain*(): void =
  var tuckˑvˑconfig = tuckˑtypeˑConfig(url: "https://example.com")
  var tuckˑvˑfeed = tuckˑtypeˑFeed(title: "Deep Dive")
  var tuckˑvˑp = tuckˑtypeˑPlayerState(kind: Ready, tuckˑvariantˑready: (config: tuckˑvˑconfig, feed: tuckˑvˑfeed))
  var tuckˑvˑfresh = tuckˑtypeˑMqttSession(kind: Disconnected)
  var tuckˑvˑsocket = tuckˑtypeˑSocket(fd: 3)
  var tuckˑvˑsession = tuckˑtypeˑMqttSession(kind: Connected, tuckˑvariantˑconnected: (socket: tuckˑvˑsocket, keepalive: 60'u16))
  return

