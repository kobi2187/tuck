{.experimental: "codeReordering".}
import "../compiler/tuck_rt"

proc `==`*(a, b: tuckˑtypeˑPlayerState): bool {.noSideEffect.}
proc tuckDrop*(x: var tuckˑtypeˑPlayerState)
proc `==`*(a, b: tuckˑtypeˑMqttSession): bool {.noSideEffect.}
proc tuckDrop*(x: var tuckˑtypeˑMqttSession)

proc tuckˑfnˑmain*(): void

type tuckˑtypeˑConfig* = object
  url*: string

type tuckˑtypeˑFeed* = object
  title*: string

type tuckˑtypeˑSocket* = object
  fd*: int

type
  tuckˑtypeˑPlayerStateKind* = enum Unloaded, Loading, Ready
  tuckˑtypeˑPlayerState_Unloaded* = object
    config*: tuckˑtypeˑConfig
  tuckˑtypeˑPlayerState_Loading* = object
    config*: tuckˑtypeˑConfig
    progress*: int
  tuckˑtypeˑPlayerState_Ready* = object
    config*: tuckˑtypeˑConfig
    feed*: tuckˑtypeˑFeed
  tuckˑtypeˑPlayerState* = object
    case kind*: tuckˑtypeˑPlayerStateKind
    of Unloaded: tuckˑvariantˑunloaded*: tuckˑtypeˑPlayerState_Unloaded
    of Loading: tuckˑvariantˑloading*: tuckˑtypeˑPlayerState_Loading
    of Ready: tuckˑvariantˑready*: tuckˑtypeˑPlayerState_Ready

proc `==`*(a, b: tuckˑtypeˑPlayerState): bool {.noSideEffect.} =
  if a.kind != b.kind: return false
  case a.kind
  of Unloaded: a.tuckˑvariantˑunloaded == b.tuckˑvariantˑunloaded
  of Loading: a.tuckˑvariantˑloading == b.tuckˑvariantˑloading
  of Ready: a.tuckˑvariantˑready == b.tuckˑvariantˑready

proc tuckDrop*(x: var tuckˑtypeˑPlayerState) =
  case x.kind
  of Unloaded: tuckDrop(x.tuckˑvariantˑunloaded)
  of Loading: tuckDrop(x.tuckˑvariantˑloading)
  of Ready: tuckDrop(x.tuckˑvariantˑready)
proc canTransition*(frm, to: tuckˑtypeˑPlayerStateKind): bool =
  case frm
  of Unloaded: to in {Loading}
  of Loading: to in {Ready, Unloaded}
  of Ready: false
proc transitionTo*(self: var tuckˑtypeˑPlayerState, target: tuckˑtypeˑPlayerState) =
  if not canTransition(self.kind, target.kind):
    raise newException(ValueError, "Invalid transition " & $self.kind & " -> " & $target.kind)
  self = target

type
  tuckˑtypeˑMqttSessionKind* = enum Disconnected, Connecting, Connected, Subscribing
  tuckˑtypeˑMqttSession_Connecting* = object
    host*: string
    port*: uint16
  tuckˑtypeˑMqttSession_Connected* = object
    socket*: tuckˑtypeˑSocket
    keepalive*: uint16
  tuckˑtypeˑMqttSession_Subscribing* = object
    socket*: tuckˑtypeˑSocket
    topic*: string
  tuckˑtypeˑMqttSession* = object
    case kind*: tuckˑtypeˑMqttSessionKind
    of Disconnected: discard
    of Connecting: tuckˑvariantˑconnecting*: tuckˑtypeˑMqttSession_Connecting
    of Connected: tuckˑvariantˑconnected*: tuckˑtypeˑMqttSession_Connected
    of Subscribing: tuckˑvariantˑsubscribing*: tuckˑtypeˑMqttSession_Subscribing

proc `==`*(a, b: tuckˑtypeˑMqttSession): bool {.noSideEffect.} =
  if a.kind != b.kind: return false
  case a.kind
  of Disconnected: true
  of Connecting: a.tuckˑvariantˑconnecting == b.tuckˑvariantˑconnecting
  of Connected: a.tuckˑvariantˑconnected == b.tuckˑvariantˑconnected
  of Subscribing: a.tuckˑvariantˑsubscribing == b.tuckˑvariantˑsubscribing

proc tuckDrop*(x: var tuckˑtypeˑMqttSession) =
  case x.kind
  of Disconnected: discard
  of Connecting: tuckDrop(x.tuckˑvariantˑconnecting)
  of Connected: tuckDrop(x.tuckˑvariantˑconnected)
  of Subscribing: tuckDrop(x.tuckˑvariantˑsubscribing)
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
  var tuckˑvˑconfig = tuckˑtypeˑConfig(url: tuckCopy("https://example.com"))
  var tuckˑvˑfeed = tuckˑtypeˑFeed(title: tuckCopy("Deep Dive"))
  var tuckˑvˑp = tuckˑtypeˑPlayerState(kind: Ready, tuckˑvariantˑready: tuckˑtypeˑPlayerState_Ready(config: tuckMove(tuckˑvˑconfig), feed: tuckMove(tuckˑvˑfeed)))
  defer: tuckDrop(tuckˑvˑp)
  var tuckˑvˑfresh = tuckˑtypeˑMqttSession(kind: Disconnected)
  defer: tuckDrop(tuckˑvˑfresh)
  var tuckˑvˑsocket = tuckˑtypeˑSocket(fd: 3)
  var tuckˑvˑsession = tuckˑtypeˑMqttSession(kind: Connected, tuckˑvariantˑconnected: tuckˑtypeˑMqttSession_Connected(socket: tuckˑvˑsocket, keepalive: 60'u16))
  defer: tuckDrop(tuckˑvˑsession)
  return

