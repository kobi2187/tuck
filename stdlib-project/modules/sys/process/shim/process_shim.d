// D impl module for sys.process — the twin of process_shim.nim.
// posix_spawnp and three pipes; the pid and descriptors stay here and Tuck
// holds a handle. Reads answer a status byte then the data: 0 data, 1 end of
// stream, 2 timed out.
module process_shim;

import std.string : toStringz, split;

private struct FileActions { ulong[10] pad; }
private struct PollFd { int fd; short events; short revents; }

private extern (C) nothrow @nogc
{
    int posix_spawnp(int* pid, const(char)* file, FileActions* fa, void* attr,
                     const(char)** argv, const(char)** envp);
    int posix_spawn_file_actions_init(FileActions* fa);
    int posix_spawn_file_actions_destroy(FileActions* fa);
    int posix_spawn_file_actions_adddup2(FileActions* fa, int fd, int newfd);
    int posix_spawn_file_actions_addclose(FileActions* fa, int fd);
    int pipe(int* fds);
    int close(int fd);
    ptrdiff_t read(int fd, void* buf, size_t n);
    ptrdiff_t write(int fd, const(void)* buf, size_t n);
    int poll(void* fds, ulong n, int to);
    int waitpid(int pid, int* status, int options);
    int kill(int pid, int sig);
    int fcntl(int fd, int cmd, ...);
    void* signal(int sig, void* handler);
    extern __gshared const(char)** environ;
}

private struct Child
{
    int pid;
    int inFd, outFd, errFd;
    bool live;
    long status;
    bool done;
}

private __gshared Child[] gKids;
private __gshared bool ignoredPipe = false;

private bool valid(long h) { return h >= 0 && h < gKids.length && gKids[cast(size_t) h].live; }

/// Handle >= 0, or -1 when the program cannot be started. `argv` is the program
/// and its arguments separated by NUL bytes.
long procSpawn(string argv)
{
    if (!ignoredPipe)
    {
        signal(13, cast(void*) 1);
        ignoredPipe = true;
    }
    auto parts = argv.split('\0');
    if (parts.length == 0 || parts[0].length == 0) return -1;
    auto cargs = new const(char)*[parts.length + 1];
    foreach (i, p; parts) cargs[i] = toStringz(p);
    cargs[parts.length] = null;
    int[2] inP, outP, errP;
    if (pipe(inP.ptr) != 0 || pipe(outP.ptr) != 0 || pipe(errP.ptr) != 0) return -1;
    FileActions fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, inP[0], 0);
    posix_spawn_file_actions_adddup2(&fa, outP[1], 1);
    posix_spawn_file_actions_adddup2(&fa, errP[1], 2);
    foreach (fd; [inP[0], inP[1], outP[0], outP[1], errP[0], errP[1]])
        posix_spawn_file_actions_addclose(&fa, fd);
    int pid;
    auto rc = posix_spawnp(&pid, cargs[0], &fa, null, cargs.ptr, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(inP[0]); close(outP[1]); close(errP[1]);
    if (rc != 0)
    {
        close(inP[1]); close(outP[0]); close(errP[0]);
        return -1;
    }
    foreach (fd; [inP[1], outP[0], errP[0]]) fcntl(fd, 2, 1);
    gKids ~= Child(pid, inP[1], outP[0], errP[0], true, 0, false);
    return cast(long) gKids.length - 1;
}

long procPid(long h)
{
    if (!valid(h)) return 0;
    return gKids[cast(size_t) h].pid;
}

/// Bytes written, or -1.
long procWrite(long h, string data)
{
    if (!valid(h) || gKids[cast(size_t) h].inFd < 0) return -1;
    if (data.length == 0) return 0;
    return write(gKids[cast(size_t) h].inFd, data.ptr, data.length);
}

void procCloseIn(long h)
{
    if (!valid(h) || gKids[cast(size_t) h].inFd < 0) return;
    close(gKids[cast(size_t) h].inFd);
    gKids[cast(size_t) h].inFd = -1;
}

/// [status] ~ data from stdout (which = 1) or stderr (2).
ubyte[] procRead(long h, long which, long max, long timeoutMs)
{
    if (!valid(h)) return [cast(ubyte) 1];
    auto k = &gKids[cast(size_t) h];
    int fd = which == 2 ? k.errFd : k.outFd;
    if (fd < 0) return [cast(ubyte) 1];
    PollFd p = PollFd(fd, 1, 0);
    if (poll(&p, 1, cast(int) timeoutMs) == 0) return [cast(ubyte) 2];
    size_t want = max > 1 ? cast(size_t) max : 1;
    auto buf = new ubyte[want + 1];
    auto n = read(fd, buf.ptr + 1, want);
    if (n <= 0) return [cast(ubyte) 1];
    buf[0] = 0;
    return buf[0 .. n + 1];
}

private long decode(int st)
{
    if ((st & 0x7f) == 0) return (st >> 8) & 0xff;
    if ((st & 0x7f) != 0x7f) return 128 + (st & 0x7f);
    return st;
}

private long reap(long h, int flags)
{
    auto k = &gKids[cast(size_t) h];
    if (k.done) return k.status;
    int st;
    auto r = waitpid(k.pid, &st, flags);
    if (r == 0) return -1;
    k.status = r < 0 ? 127 : decode(st);
    k.done = true;
    foreach (fd; [k.inFd, k.outFd, k.errFd]) if (fd >= 0) close(fd);
    k.inFd = -1; k.outFd = -1; k.errFd = -1;
    return k.status;
}

long procWait(long h)
{
    if (!valid(h)) return 127;
    return reap(h, 0);
}

long procPoll(long h)
{
    if (!valid(h)) return 127;
    return reap(h, 1);
}

long procKill(long h, long sig)
{
    if (!valid(h) || gKids[cast(size_t) h].done) return -1;
    return kill(gKids[cast(size_t) h].pid, cast(int) sig);
}
