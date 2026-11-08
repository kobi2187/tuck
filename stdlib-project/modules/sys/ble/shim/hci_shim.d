// D impl module for sys.ble's Linux HCI scanner — the twin of hci_shim.nim.
module hci_shim;

import core.stdc.errno : errno, EPERM, EACCES;

pragma(lib, "bluetooth");

private extern (C) nothrow @nogc
{
    int hci_open_dev(int dev);
    int hci_le_set_scan_parameters(int dd, ubyte kind, ushort interval, ushort window,
                                   ubyte own, ubyte filter, int to);
    int hci_le_set_scan_enable(int dd, ubyte enable, ubyte filterDup, int to);
    int hci_close_dev(int dd);
    int setsockopt(int fd, int level, int name, const(void)* val, uint len);
    int poll(void* fds, ulong n, int to);
    ptrdiff_t read(int fd, void* buf, size_t n);
}

private struct PollFd
{
    int fd;
    short events;
    short revents;
}

private __gshared int[] gSocks;

private bool valid(long h) { return h >= 0 && h < gSocks.length && gSocks[cast(size_t) h] >= 0; }

/// A scanner handle >= 0; -1 no such adapter; -2 not permitted / refused.
long hciOpen(long adapter)
{
    auto dd = hci_open_dev(cast(int) adapter);
    if (dd < 0) return (errno == EPERM || errno == EACCES) ? -2 : -1;
    if (hci_le_set_scan_parameters(dd, 0, 0x0010, 0x0010, 0, 0, 1000) < 0 ||
        hci_le_set_scan_enable(dd, 1, 0, 1000) < 0)
    {
        hci_close_dev(dd);
        return -2;
    }
    ubyte[16] filter;
    filter[0] = 1 << 4;
    filter[8 + 3] = 1 << (62 - 32 - 24);
    setsockopt(dd, 0, 2, filter.ptr, 14);
    gSocks ~= dd;
    return cast(long) gSocks.length - 1;
}

/// One packet, or empty after the timeout.
ubyte[] hciRead(long h, long timeoutMs)
{
    if (!valid(h)) return [];
    PollFd p = PollFd(gSocks[cast(size_t) h], 1, 0);
    if (poll(&p, 1, cast(int) timeoutMs) <= 0) return [];
    ubyte[260] buf;
    auto n = read(gSocks[cast(size_t) h], buf.ptr, 260);
    if (n <= 0) return [];
    return buf[0 .. n].dup;
}

void hciClose(long h)
{
    if (!valid(h)) return;
    hci_le_set_scan_enable(gSocks[cast(size_t) h], 0, 0, 1000);
    hci_close_dev(gSocks[cast(size_t) h]);
    gSocks[cast(size_t) h] = -1;
}
