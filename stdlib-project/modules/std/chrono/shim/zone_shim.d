// D impl module for std.chrono's time zones — the twin of zone_shim.nim.
// The rules are the OS tz database read through libc. NOT thread-safe: libc
// keeps the zone in the TZ variable.
module zone_shim;

import std.file : exists;
import std.string : toStringz, indexOf;

private struct Tm
{
    int[9] f;
    int pad;
    long gmtoff;
    const(char)* zone;
}

private extern (C) nothrow @nogc
{
    void* localtime_r(const(long)* t, Tm* tm);
    void tzset();
    int setenv(const(char)* name, const(char)* value, int overwrite);
}

private enum NoZone = 999999;

private bool zoneOk(string zone)
{
    if (zone.length == 0 || zone[0] == '/' || zone[0] == ':' || zone.indexOf("..") >= 0) return false;
    if (zone == "UTC") return true;
    return exists("/usr/share/zoneinfo/" ~ zone);
}

private bool here(string zone, long t, ref Tm tm)
{
    if (!zoneOk(zone)) return false;
    setenv("TZ", toStringz(zone), 1);
    tzset();
    return localtime_r(&t, &tm) !is null;
}

/// Seconds east of UTC in force then, or 999999 for an unknown zone.
long tzOffsetAt(string zone, long epochSec)
{
    Tm tm;
    if (!here(zone, epochSec, tm)) return NoZone;
    return tm.gmtoff;
}

long tzIsDst(string zone, long epochSec)
{
    Tm tm;
    if (!here(zone, epochSec, tm)) return 0;
    return tm.f[8] > 0 ? 1 : 0;
}

ubyte[] tzAbbrev(string zone, long epochSec)
{
    Tm tm;
    if (!here(zone, epochSec, tm) || tm.zone is null) return [];
    ubyte[] r;
    for (size_t i = 0; tm.zone[i] != 0; i++) r ~= cast(ubyte) tm.zone[i];
    return r;
}
