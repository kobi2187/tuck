// Odin impl module for sys.process — the twin of process_shim.nim.
// posix_spawnp and three pipes; the pid and descriptors stay here and Tuck
// holds a handle. Reads answer a status byte then the data: 0 data, 1 end of
// stream, 2 timed out.
package process_shim

import "core:c"
import "core:strings"

foreign import libc "system:c"

@(private) FileActions :: struct #align(8) { _: [80]u8 }
@(private) PollFd :: struct #packed { fd: c.int, events: i16, revents: i16 }

@(default_calling_convention = "c", private)
foreign libc {
	posix_spawnp :: proc(pid: ^c.int, file: cstring, fa: ^FileActions, attr: rawptr, argv: [^]cstring, envp: [^]cstring) -> c.int ---
	posix_spawn_file_actions_init :: proc(fa: ^FileActions) -> c.int ---
	posix_spawn_file_actions_destroy :: proc(fa: ^FileActions) -> c.int ---
	posix_spawn_file_actions_adddup2 :: proc(fa: ^FileActions, fd, newfd: c.int) -> c.int ---
	posix_spawn_file_actions_addclose :: proc(fa: ^FileActions, fd: c.int) -> c.int ---
	pipe :: proc(fds: ^[2]c.int) -> c.int ---
	close :: proc(fd: c.int) -> c.int ---
	read :: proc(fd: c.int, buf: rawptr, n: c.size_t) -> c.ssize_t ---
	write :: proc(fd: c.int, buf: rawptr, n: c.size_t) -> c.ssize_t ---
	poll :: proc(fds: ^PollFd, n: c.ulong, to: c.int) -> c.int ---
	waitpid :: proc(pid: c.int, status: ^c.int, options: c.int) -> c.int ---
	kill :: proc(pid: c.int, sig: c.int) -> c.int ---
	fcntl :: proc(fd: c.int, cmd: c.int, #c_vararg args: ..any) -> c.int ---
	signal :: proc(sig: c.int, handler: rawptr) -> rawptr ---
	environ: [^]cstring
}

@(private) Child :: struct {
	pid:                  c.int,
	inFd, outFd, errFd:   c.int,
	live:                 bool,
	status:               int,
	done:                 bool,
}

@(private) gKids: [dynamic]Child
@(private) ignoredPipe := false

@(private)
valid :: proc(h: int) -> bool { return h >= 0 && h < len(gKids) && gKids[h].live }

// Handle >= 0, or -1 when the program cannot be started. `argv` is the program
// and its arguments separated by NUL bytes.
procSpawn :: proc(argv: string) -> int {
	if !ignoredPipe {
		signal(13, rawptr(uintptr(1)))   // SIGPIPE, SIG_IGN
		ignoredPipe = true
	}
	parts := strings.split(argv, "\x00", context.temp_allocator)
	if len(parts) == 0 || len(parts[0]) == 0 do return -1
	cargs := make([]cstring, len(parts) + 1, context.temp_allocator)
	for p, i in parts do cargs[i] = strings.clone_to_cstring(p, context.temp_allocator)
	cargs[len(parts)] = nil
	inP, outP, errP: [2]c.int
	if pipe(&inP) != 0 || pipe(&outP) != 0 || pipe(&errP) != 0 do return -1
	fa: FileActions
	posix_spawn_file_actions_init(&fa)
	posix_spawn_file_actions_adddup2(&fa, inP[0], 0)
	posix_spawn_file_actions_adddup2(&fa, outP[1], 1)
	posix_spawn_file_actions_adddup2(&fa, errP[1], 2)
	for fd in ([6]c.int{inP[0], inP[1], outP[0], outP[1], errP[0], errP[1]}) {
		posix_spawn_file_actions_addclose(&fa, fd)
	}
	pid: c.int
	rc := posix_spawnp(&pid, cargs[0], &fa, nil, raw_data(cargs), environ)
	posix_spawn_file_actions_destroy(&fa)
	close(inP[0]); close(outP[1]); close(errP[1])
	if rc != 0 {
		close(inP[1]); close(outP[0]); close(errP[0])
		return -1
	}
	for fd in ([3]c.int{inP[1], outP[0], errP[0]}) do fcntl(fd, 2, 1)   // F_SETFD, FD_CLOEXEC
	append(&gKids, Child{pid = pid, inFd = inP[1], outFd = outP[0], errFd = errP[0], live = true})
	return len(gKids) - 1
}

procPid :: proc(h: int) -> int {
	if !valid(h) do return 0
	return int(gKids[h].pid)
}

// Bytes written, or -1.
procWrite :: proc(h: int, data: string) -> int {
	if !valid(h) || gKids[h].inFd < 0 do return -1
	if len(data) == 0 do return 0
	return int(write(gKids[h].inFd, raw_data(data), c.size_t(len(data))))
}

procCloseIn :: proc(h: int) {
	if !valid(h) || gKids[h].inFd < 0 do return
	close(gKids[h].inFd)
	gKids[h].inFd = -1
}

// [status] ++ data from stdout (which = 1) or stderr (2).
procRead :: proc(h: int, which: int, max_: int, timeoutMs: int) -> [dynamic]u8 {
	out := make([dynamic]u8)
	if !valid(h) {
		append(&out, 1)
		return out
	}
	fd := which == 2 ? gKids[h].errFd : gKids[h].outFd
	if fd < 0 {
		append(&out, 1)
		return out
	}
	p := PollFd{fd = fd, events = 1}
	if poll(&p, 1, c.int(timeoutMs)) == 0 {
		append(&out, 2)
		return out
	}
	want := max(max_, 1)
	buf := make([]u8, want, context.temp_allocator)
	n := int(read(fd, raw_data(buf), c.size_t(want)))
	if n <= 0 {
		append(&out, 1)
		return out
	}
	append(&out, 0)
	for i in 0 ..< n do append(&out, buf[i])
	return out
}

@(private)
decode :: proc(st: c.int) -> int {
	if st & 0x7f == 0 do return int((st >> 8) & 0xff)
	if ((st & 0x7f) + 1) >> 1 > 0 && st & 0x7f != 0x7f do return 128 + int(st & 0x7f)
	return int(st)
}

@(private)
reap :: proc(h: int, flags: c.int) -> int {
	if gKids[h].done do return gKids[h].status
	st: c.int
	r := waitpid(gKids[h].pid, &st, flags)
	if r == 0 do return -1
	gKids[h].status = r < 0 ? 127 : decode(st)
	gKids[h].done = true
	for fd in ([3]c.int{gKids[h].inFd, gKids[h].outFd, gKids[h].errFd}) {
		if fd >= 0 do close(fd)
	}
	gKids[h].inFd = -1
	gKids[h].outFd = -1
	gKids[h].errFd = -1
	return gKids[h].status
}

procWait :: proc(h: int) -> int {
	if !valid(h) do return 127
	return reap(h, 0)
}

procPoll :: proc(h: int) -> int {
	if !valid(h) do return 127
	return reap(h, 1)   // WNOHANG
}

procKill :: proc(h: int, sig: int) -> int {
	if !valid(h) || gKids[h].done do return -1
	return int(kill(gKids[h].pid, c.int(sig)))
}
