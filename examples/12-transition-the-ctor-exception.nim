{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc `==`*(a, b: tuck_type_PlayerState): bool {.noSideEffect.}
proc `==`*(a, b: tuck_type_MqttSession): bool {.noSideEffect.}

proc tuck_fn_main*(): void

type tuck_type_Config* = object
  url*: string

type tuck_type_Feed* = object
  title*: string

type tuck_type_Socket* = object
  fd*: int

type tuck_type_PlayerStateKind* = enum Unloaded, Loading, Ready
type tuck_type_PlayerState* = object
  case kind*: tuck_type_PlayerStateKind
  of Unloaded: tuck_unloaded*: tuple[config: tuck_type_Config]
  of Loading: tuck_loading*: tuple[config: tuck_type_Config, progress: int]
  of Ready: tuck_ready*: tuple[config: tuck_type_Config, feed: tuck_type_Feed]

proc `==`*(a, b: tuck_type_PlayerState): bool {.noSideEffect.} =
  if a.kind != b.kind: return false
  case a.kind
  of Unloaded: a.tuck_unloaded == b.tuck_unloaded
  of Loading: a.tuck_loading == b.tuck_loading
  of Ready: a.tuck_ready == b.tuck_ready
proc canTransition*(frm, to: tuck_type_PlayerStateKind): bool =
  case frm
  of Unloaded: to in {Loading}
  of Loading: to in {Ready, Unloaded}
  of Ready: false
proc transitionTo*(self: var tuck_type_PlayerState, target: tuck_type_PlayerState) =
  if not canTransition(self.kind, target.kind):
    raise newException(ValueError, "Invalid transition " & $self.kind & " -> " & $target.kind)
  self = target

type tuck_type_MqttSessionKind* = enum Disconnected, Connecting, Connected, Subscribing
type tuck_type_MqttSession* = object
  case kind*: tuck_type_MqttSessionKind
  of Disconnected: discard
  of Connecting: tuck_connecting*: tuple[host: string, port: uint16]
  of Connected: tuck_connected*: tuple[socket: tuck_type_Socket, keepalive: uint16]
  of Subscribing: tuck_subscribing*: tuple[socket: tuck_type_Socket, topic: string]

proc `==`*(a, b: tuck_type_MqttSession): bool {.noSideEffect.} =
  if a.kind != b.kind: return false
  case a.kind
  of Disconnected: true
  of Connecting: a.tuck_connecting == b.tuck_connecting
  of Connected: a.tuck_connected == b.tuck_connected
  of Subscribing: a.tuck_subscribing == b.tuck_subscribing
proc canTransition*(frm, to: tuck_type_MqttSessionKind): bool =
  case frm
  of Disconnected: to in {Connecting}
  of Connecting: to in {Connected, Disconnected}
  of Connected: to in {Subscribing}
  of Subscribing: to in {Connected}
proc transitionTo*(self: var tuck_type_MqttSession, target: tuck_type_MqttSession) =
  if not canTransition(self.kind, target.kind):
    raise newException(ValueError, "Invalid transition " & $self.kind & " -> " & $target.kind)
  self = target

proc tuck_fn_main*(): void =
  var tuck_config = tuck_type_Config(url: "https://example.com")
  var tuck_feed = tuck_type_Feed(title: "Deep Dive")
  var tuck_p = tuck_type_PlayerState(kind: Ready, tuck_ready: (config: tuck_config, feed: tuck_feed))
  var tuck_fresh = tuck_type_MqttSession(kind: Disconnected)
  var tuck_socket = tuck_type_Socket(fd: 3)
  var tuck_session = tuck_type_MqttSession(kind: Connected, tuck_connected: (socket: tuck_socket, keepalive: 60'u16))
  return

