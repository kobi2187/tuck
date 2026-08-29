{.experimental: "codeReordering".}
import ../compiler/tuck_rt

type tuck_Config* = object
  url*: string

type tuck_Feed* = object
  title*: string

type tuck_Socket* = object
  fd*: int

type tuck_PlayerStateKind* = enum Unloaded, Loading, Ready
type tuck_PlayerState* = object
  case kind*: tuck_PlayerStateKind
  of Unloaded: unloaded*: tuple[config: tuck_Config]
  of Loading: loading*: tuple[config: tuck_Config, progress: int]
  of Ready: ready*: tuple[config: tuck_Config, feed: tuck_Feed]
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
  of Connecting: connecting*: tuple[host: string, port: uint16]
  of Connected: connected*: tuple[socket: tuck_Socket, keepalive: uint16]
  of Subscribing: subscribing*: tuple[socket: tuck_Socket, topic: string]
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
  var config = tuck_Config(url: "https://example.com")
  var feed = tuck_Feed(title: "Deep Dive")
  var p = tuck_PlayerState(kind: Ready, ready: (config: config, feed: feed))
  var fresh = tuck_MqttSession(kind: Disconnected)
  var socket = tuck_Socket(fd: 3)
  var session = tuck_MqttSession(kind: Connected, connected: (socket: socket, keepalive: 60))
  return

