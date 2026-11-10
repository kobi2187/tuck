// D impl module for std.db's sqlite3 driver — the twin of sqlite_shim.nim.
// Same contract: sqlite3 pointers stay in these tables, Tuck holds handles,
// and text comes back as bytes.
module sqlite_shim;

import std.string : toStringz;

pragma(lib, "sqlite3");

private extern (C) nothrow @nogc
{
    int sqlite3_open(const(char)* path, void** db);
    int sqlite3_close(void* db);
    int sqlite3_exec(void* db, const(char)* sql, void* cb, void* arg, void* err);
    int sqlite3_prepare_v2(void* db, const(char)* sql, int n, void** s, void* tail);
    int sqlite3_finalize(void* s);
    int sqlite3_step(void* s);
    int sqlite3_bind_int64(void* s, int i, long v);
    int sqlite3_bind_double(void* s, int i, double v);
    int sqlite3_bind_text(void* s, int i, const(char)* v, int n, void* d);
    int sqlite3_bind_null(void* s, int i);
    int sqlite3_column_count(void* s);
    int sqlite3_column_type(void* s, int i);
    long sqlite3_column_int64(void* s, int i);
    double sqlite3_column_double(void* s, int i);
    const(ubyte)* sqlite3_column_text(void* s, int i);
    int sqlite3_column_bytes(void* s, int i);
    const(char)* sqlite3_errmsg(void* db);
}

private __gshared void*[] gDbs;
private __gshared void*[] gStmts;

private bool dbValid(long h) { return h >= 0 && h < gDbs.length && gDbs[cast(size_t) h] !is null; }
private bool stmtValid(long s) { return s >= 0 && s < gStmts.length && gStmts[cast(size_t) s] !is null; }

/// A connection handle >= 0, or -1.
long dbOpen(string path)
{
    void* db;
    if (sqlite3_open(toStringz(path), &db) != 0)
    {
        if (db !is null) sqlite3_close(db);
        return -1;
    }
    gDbs ~= db;
    return cast(long) gDbs.length - 1;
}

void dbClose(long h)
{
    if (!dbValid(h)) return;
    sqlite3_close(gDbs[cast(size_t) h]);
    gDbs[cast(size_t) h] = null;
}

/// The sqlite result code (0 = ok); -1 for a bad handle.
long dbExec(long h, string sql)
{
    if (!dbValid(h)) return -1;
    return sqlite3_exec(gDbs[cast(size_t) h], toStringz(sql), null, null, null);
}

ubyte[] dbError(long h)
{
    if (!dbValid(h)) return [];
    auto m = sqlite3_errmsg(gDbs[cast(size_t) h]);
    ubyte[] out_;
    for (size_t i = 0; m[i] != 0; i++) out_ ~= cast(ubyte) m[i];
    return out_;
}

/// A statement handle >= 0, or -1.
long stmtPrepare(long h, string sql)
{
    if (!dbValid(h)) return -1;
    void* s;
    if (sqlite3_prepare_v2(gDbs[cast(size_t) h], toStringz(sql), cast(int) sql.length, &s, null) != 0)
        return -1;
    gStmts ~= s;
    return cast(long) gStmts.length - 1;
}

void stmtFinalize(long s)
{
    if (!stmtValid(s)) return;
    sqlite3_finalize(gStmts[cast(size_t) s]);
    gStmts[cast(size_t) s] = null;
}

long stmtBindInt(long s, long idx, long v)
{
    if (!stmtValid(s)) return -1;
    return sqlite3_bind_int64(gStmts[cast(size_t) s], cast(int) idx, v);
}

long stmtBindReal(long s, long idx, double v)
{
    if (!stmtValid(s)) return -1;
    return sqlite3_bind_double(gStmts[cast(size_t) s], cast(int) idx, v);
}

long stmtBindText(long s, long idx, string v)
{
    if (!stmtValid(s)) return -1;
    return sqlite3_bind_text(gStmts[cast(size_t) s], cast(int) idx, v.ptr, cast(int) v.length,
                             cast(void*) -1);
}

long stmtBindNull(long s, long idx)
{
    if (!stmtValid(s)) return -1;
    return sqlite3_bind_null(gStmts[cast(size_t) s], cast(int) idx);
}

/// 100 = a row, 101 = done, else an error code; -1 for a bad handle.
long stmtStep(long s)
{
    if (!stmtValid(s)) return -1;
    return sqlite3_step(gStmts[cast(size_t) s]);
}

long stmtColumns(long s)
{
    if (!stmtValid(s)) return 0;
    return sqlite3_column_count(gStmts[cast(size_t) s]);
}

/// 1 integer, 2 float, 3 text, 4 blob, 5 null.
long stmtColumnType(long s, long col)
{
    if (!stmtValid(s)) return 5;
    return sqlite3_column_type(gStmts[cast(size_t) s], cast(int) col);
}

long stmtColumnInt(long s, long col)
{
    if (!stmtValid(s)) return 0;
    return sqlite3_column_int64(gStmts[cast(size_t) s], cast(int) col);
}

double stmtColumnReal(long s, long col)
{
    if (!stmtValid(s)) return 0;
    return sqlite3_column_double(gStmts[cast(size_t) s], cast(int) col);
}

ubyte[] stmtColumnText(long s, long col)
{
    if (!stmtValid(s)) return [];
    auto p = sqlite3_column_text(gStmts[cast(size_t) s], cast(int) col);
    auto n = sqlite3_column_bytes(gStmts[cast(size_t) s], cast(int) col);
    if (p is null || n <= 0) return [];
    return p[0 .. n].dup;
}
