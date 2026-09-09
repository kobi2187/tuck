{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc `==`*(a, b: tuck_PlayerState): bool {.noSideEffect.}
proc `==`*(a, b: tuck_MqttSession): bool {.noSideEffect.}

proc tuck_main*(): void

type tuck_Config* = object
  url*: string

type tuck_Feed* = object
  title*: string

type tuck_Socket* = object
  fd*: int

type tuck_PlayerStateKind* = enum Unloaded, Loading, Ready
type tuck_PlayerState* = object
  case kind*: tuck_PlayerStateKind
  of Unloaded: tuck_unloaded*: tuple[config: tuck_Config]
  of Loading: tuck_loading*: tuple[config: tuck_Config, progress: int]
  of Ready: tuck_ready*: tuple[config: tuck_Config, feed: tuck_Feed]

proc `==`*(a, b: tuck_PlayerState): bool {.noSideEffect.} =
  if a.kind != b.kind: return false
  case a.kind
  of Unloaded: a.tuck_unloaded == b.tuck_unloaded
  of Loading: a.tuck_loading == b.tuck_loading
  of Ready: a.tuck_ready == b.tuck_ready
proc canTransition*(frm, to: tuck_PlayerStateKind): bool =
  case frm
  of Unloaded: to in {Loading}
  of Loading: to in {Ready, Unloaded}
  of Ready: false
proc transitionTo*(self: var tuck_PlayerState, target: tuck_PlayerState) =
  if not canTransition(self.kind, target.kind):
    raise newException(ValueError, "Invalid transition " & $self.kind & " -> " & $target.kind)
  self = target

type tuck_MqttSessionKind* = enum Disconnected, Connecting, Connected, Subscribing
type tuck_MqttSession* = object
  case kind*: tuck_MqttSessionKind
  of Disconnected: discard
  of Connecting: tuck_connecting*: tuple[host: string, port: uint16]
  of Connected: tuck_connected*: tuple[socket: tuck_Socket, keepalive: uint16]
  of Subscribing: tuck_subscribing*: tuple[socket: tuck_Socket, topic: string]

proc `==`*(a, b: tuck_MqttSession): bool {.noSideEffect.} =
  if a.kind != b.kind: return false
  case a.kind
  of Disconnected: true
  of Connecting: a.tuck_connecting == b.tuck_connecting
  of Connected: a.tuck_connected == b.tuck_connected
  of Subscribing: a.tuck_subscribing == b.tuck_subscribing
proc canTransition*(frm, to: tuck_MqttSessionKind): bool =
  case frm
  of Disconnected: to in {Connecting}
  of Connecting: to in {Connected, Disconnected}
  of Connected: to in {Subscribing}
  of Subscribing: to in {Connected}
proc transitionTo*(self: var tuck_MqttSession, target: tuck_MqttSession) =
  if not canTransition(self.kind, target.kind):
    raise newException(ValueError, "Invalid transition " & $self.kind & " -> " & $target.kind)
  self = target

proc tuck_main*(): void =
  var tuck_config = tuck_Config(url: "https://example.com")
  var tuck_feed = tuck_Feed(title: "Deep Dive")
  var tuck_p = tuck_PlayerState(kind: Ready, tuck_ready: (config: tuck_config, feed: tuck_feed))
  var tuck_fresh = tuck_MqttSession(kind: Disconnected)
  var tuck_socket = tuck_Socket(fd: 3)
  var tuck_session = tuck_MqttSession(kind: Connected, tuck_connected: (socket: tuck_socket, keepalive: 60))
  return

