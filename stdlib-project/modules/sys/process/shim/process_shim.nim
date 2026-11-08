# Nim impl module for sys.process — twins: process_shim.odin and process_shim.d.
# A child is started with posix_spawnp and three pipes; the pid and the pipe
# descriptors stay in this table and Tuck holds a HANDLE. Reads answer a status
# byte then the data: 0 data, 1 end of stream, 2 timed out.
import std/posix

{.emit: "#include <spawn.h>\n#include <fcntl.h>\n#include <signal.h>\n#include <poll.h>".}

type FileActions {.importc: "posix_spawn_file_actions_t", header: "<spawn.h>".} = object

proc posix_spawnp(pid: ptr cint, file: cstring, fa: ptr FileActions, attr: pointer,
                  argv: cstringArray, envp: cstringArray): cint {.importc, header: "<spawn.h>", cdecl.}
proc posix_spawn_file_actions_init(fa: ptr FileActions): cint {.importc, header: "<spawn.h>", cdecl.}
proc posix_spawn_file_actions_destroy(fa: ptr FileActions): cint {.importc, header: "<spawn.h>", cdecl.}
proc posix_spawn_file_actions_adddup2(fa: ptr FileActions, fd, newfd: cint): cint {.importc, header: "<spawn.h>", cdecl.}
proc posix_spawn_file_actions_addclose(fa: ptr FileActions, fd: cint): cint {.importc, header: "<spawn.h>", cdecl.}
var environ {.importc, header: "<unistd.h>".}: cstringArray

type Child = object
  pid: cint
  inFd, outFd, errFd: cint
  live: bool
  status: int
  done: bool

var gKids: seq[Child]
var ignoredPipe = false

proc valid(h: int): bool = h >= 0 and h < gKids.len and gKids[h].live

proc cloexec(fd: cint) =
  discard fcntl(fd, F_SETFD, FD_CLOEXEC)

proc procSpawn*(argv: string): int =
  ## Handle >= 0, or -1 when the program cannot be started. `argv` is the
  ## program and its arguments separated by NUL bytes.
  if not ignoredPipe:
    signal(SIGPIPE, SIG_IGN)
    ignoredPipe = true
  var parts: seq[string]
  var cur = ""
  for c in argv:
    if c == '\0':
      parts.add cur
      cur = ""
    else: cur.add c
  parts.add cur
  if parts.len == 0 or parts[0].len == 0: return -1
  var inP, outP, errP: array[2, cint]
  if pipe(inP) != 0 or pipe(outP) != 0 or pipe(errP) != 0: return -1
  var fa: FileActions
  discard posix_spawn_file_actions_init(addr fa)
  discard posix_spawn_file_actions_adddup2(addr fa, inP[0], 0)
  discard posix_spawn_file_actions_adddup2(addr fa, outP[1], 1)
  discard posix_spawn_file_actions_adddup2(addr fa, errP[1], 2)
  for fd in [inP[0], inP[1], outP[0], outP[1], errP[0], errP[1]]:
    discard posix_spawn_file_actions_addclose(addr fa, fd)
  var args = allocCStringArray(parts)
  var pid: cint
  let rc = posix_spawnp(addr pid, parts[0].cstring, addr fa, nil, args, environ)
  deallocCStringArray(args)
  discard posix_spawn_file_actions_destroy(addr fa)
  discard close(inP[0]); discard close(outP[1]); discard close(errP[1])
  if rc != 0:
    discard close(inP[1]); discard close(outP[0]); discard close(errP[0])
    return -1
  cloexec(inP[1]); cloexec(outP[0]); cloexec(errP[0])
  gKids.add Child(pid: pid, inFd: inP[1], outFd: outP[0], errFd: errP[0], live: true)
  gKids.len - 1

proc procPid*(h: int): int =
  if not valid(h): return 0
  int gKids[h].pid

proc procWrite*(h: int, data: string): int =
  ## Bytes written, or -1.
  if not valid(h) or gKids[h].inFd < 0: return -1
  if data.len == 0: return 0
  int write(gKids[h].inFd, unsafeAddr data[0], data.len)

proc procCloseIn*(h: int) =
  if not valid(h) or gKids[h].inFd < 0: return
  discard close(gKids[h].inFd)
  gKids[h].inFd = -1

proc procRead*(h, which, max, timeoutMs: int): seq[uint8] =
  ## [status] ++ data from stdout (which = 1) or stderr (2).
  if not valid(h): return @[1'u8]
  let fd = if which == 2: gKids[h].errFd else: gKids[h].outFd
  if fd < 0: return @[1'u8]
  var p = TPollfd(fd: fd, events: POLLIN)
  let r = poll(addr p, 1, cint timeoutMs)
  if r == 0: return @[2'u8]
  var buf = newSeq[uint8](max(max, 1) + 1)
  let n = read(fd, addr buf[1], max(max, 1))
  if n <= 0: return @[1'u8]
  buf[0] = 0
  buf.setLen n + 1
  buf

proc decode(st: cint): int =
  if WIFEXITED(st): int WEXITSTATUS(st)
  elif WIFSIGNALED(st): 128 + int WTERMSIG(st)
  else: int st

proc reap(h: int, flags: cint): int =
  ## -1 still running, else the status (and the pipes are released).
  if gKids[h].done: return gKids[h].status
  var st: cint
  let r = waitpid(gKids[h].pid, st, flags)
  if r == 0: return -1
  gKids[h].status = if r < 0: 127 else: decode(st)
  gKids[h].done = true
  for fd in [gKids[h].inFd, gKids[h].outFd, gKids[h].errFd]:
    if fd >= 0: discard close(fd)
  gKids[h].inFd = -1; gKids[h].outFd = -1; gKids[h].errFd = -1
  gKids[h].status

proc procWait*(h: int): int =
  if not valid(h): return 127
  reap(h, 0)

proc procPoll*(h: int): int =
  if not valid(h): return 127
  reap(h, WNOHANG)

proc procKill*(h, sig: int): int =
  if not valid(h) or gKids[h].done: return -1
  int kill(gKids[h].pid, cint sig)
