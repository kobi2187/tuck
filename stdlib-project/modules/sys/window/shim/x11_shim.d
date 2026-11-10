// D impl module for sys.window's X11 backend — the twin of x11_shim.nim.
module x11_shim;

import core.thread : Thread;
import core.time : msecs;
import std.string : toStringz;

pragma(lib, "X11");

private extern (C) nothrow @nogc
{
    void* XOpenDisplay(const(char)* name);
    int XCloseDisplay(void* d);
    int XDefaultScreen(void* d);
    c_ulong XRootWindow(void* d, int s);
    c_ulong XBlackPixel(void* d, int s);
    c_ulong XCreateSimpleWindow(void* d, c_ulong parent, int x, int y, uint w, uint h, uint bw,
                                c_ulong border, c_ulong bg);
    int XStoreName(void* d, c_ulong w, const(char)* name);
    int XSelectInput(void* d, c_ulong w, c_long mask);
    int XMapWindow(void* d, c_ulong w);
    int XDestroyWindow(void* d, c_ulong w);
    int XFlush(void* d);
    int XPending(void* d);
    int XNextEvent(void* d, void* ev);
    int XSendEvent(void* d, c_ulong w, int prop, c_long mask, void* ev);
    int XSync(void* d, int discard_);
}

import core.stdc.config : c_long, c_ulong;

private struct Win
{
    void* dpy;
    c_ulong id;
    c_ulong root;
    bool live;
}

private __gshared Win[] gWins;

private bool valid(long h) { return h >= 0 && h < gWins.length && gWins[cast(size_t) h].live; }

/// A window handle >= 0, or -1 when there is no X server.
long xOpen(string title, long w, long h)
{
    auto d = XOpenDisplay(null);
    if (d is null) return -1;
    auto s = XDefaultScreen(d);
    auto root = XRootWindow(d, s);
    auto win = XCreateSimpleWindow(d, root, 0, 0, cast(uint) w, cast(uint) h, 0, 0, XBlackPixel(d, s));
    XStoreName(d, win, toStringz(title));
    XSelectInput(d, win, 1 | 2 | 4 | 8 | 64);
    XMapWindow(d, win);
    XFlush(d);
    gWins ~= Win(d, win, root, true);
    return cast(long) gWins.length - 1;
}

private long rd(ubyte* ev, size_t off) { return *cast(int*)(ev + off); }

/// One input event as [kind, code, x, y], or empty after the timeout.
long[] xPoll(long h, long timeoutMs)
{
    if (!valid(h)) return [];
    auto w = &gWins[cast(size_t) h];
    long waited = 0;
    while (XPending(w.dpy) == 0)
    {
        if (waited >= timeoutMs) return [];
        Thread.sleep(1.msecs);
        waited++;
    }
    c_long[24] ev;
    auto p = cast(ubyte*) ev.ptr;
    while (XPending(w.dpy) > 0)
    {
        XNextEvent(w.dpy, ev.ptr);
        auto t = rd(p, 0);
        if (t == 2 || t == 3) return [t == 2 ? 1 : 2, rd(p, 84), rd(p, 64), rd(p, 68)];
        if (t == 4 || t == 5) return [t == 4 ? 3 : 4, rd(p, 84), rd(p, 64), rd(p, 68)];
        if (t == 6) return [5, 0, rd(p, 64), rd(p, 68)];
    }
    return [];
}

/// Send a key event to our own window, the way a test or a script drives input.
void xInject(long h, long code, bool down)
{
    if (!valid(h)) return;
    auto w = &gWins[cast(size_t) h];
    c_long[24] ev;
    auto p = cast(ubyte*) ev.ptr;
    *cast(int*)(p + 0) = down ? 2 : 3;
    *cast(void**)(p + 24) = w.dpy;
    *cast(c_ulong*)(p + 32) = w.id;
    *cast(c_ulong*)(p + 40) = w.root;
    *cast(int*)(p + 84) = cast(int) code;
    *cast(int*)(p + 88) = 1;
    XSendEvent(w.dpy, w.id, 0, down ? 1 : 2, ev.ptr);
    XSync(w.dpy, 0);
}

void xPresent(long h)
{
    if (valid(h)) XFlush(gWins[cast(size_t) h].dpy);
}

void xClose(long h)
{
    if (!valid(h)) return;
    auto w = &gWins[cast(size_t) h];
    XDestroyWindow(w.dpy, w.id);
    XCloseDisplay(w.dpy);
    w.live = false;
}
