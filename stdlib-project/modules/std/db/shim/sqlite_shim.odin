// Odin impl module for std.db's sqlite3 driver — the twin of sqlite_shim.nim.
// Same contract: sqlite3 pointers stay in these tables, Tuck holds handles,
// and text comes back as bytes.
package sqlite_shim

import "core:c"
import "core:strings"

foreign import sqlite "system:sqlite3"

@(private) Sqlite3 :: distinct rawptr
@(private) Stmt :: distinct rawptr

@(default_calling_convention = "c", private)
foreign sqlite {
	sqlite3_open :: proc(path: cstring, db: ^Sqlite3) -> c.int ---
	sqlite3_close :: proc(db: Sqlite3) -> c.int ---
	sqlite3_exec :: proc(db: Sqlite3, sql: cstring, cb: rawptr, arg: rawptr, err: rawptr) -> c.int ---
	sqlite3_prepare_v2 :: proc(db: Sqlite3, sql: cstring, n: c.int, s: ^Stmt, tail: rawptr) -> c.int ---
	sqlite3_finalize :: proc(s: Stmt) -> c.int ---
	sqlite3_step :: proc(s: Stmt) -> c.int ---
	sqlite3_bind_int64 :: proc(s: Stmt, i: c.int, v: i64) -> c.int ---
	sqlite3_bind_double :: proc(s: Stmt, i: c.int, v: f64) -> c.int ---
	sqlite3_bind_text :: proc(s: Stmt, i: c.int, v: cstring, n: c.int, d: rawptr) -> c.int ---
	sqlite3_bind_null :: proc(s: Stmt, i: c.int) -> c.int ---
	sqlite3_column_count :: proc(s: Stmt) -> c.int ---
	sqlite3_column_type :: proc(s: Stmt, i: c.int) -> c.int ---
	sqlite3_column_int64 :: proc(s: Stmt, i: c.int) -> i64 ---
	sqlite3_column_double :: proc(s: Stmt, i: c.int) -> f64 ---
	sqlite3_column_text :: proc(s: Stmt, i: c.int) -> [^]u8 ---
	sqlite3_column_bytes :: proc(s: Stmt, i: c.int) -> c.int ---
	sqlite3_errmsg :: proc(db: Sqlite3) -> cstring ---
}

@(private) gDbs: [dynamic]Sqlite3
@(private) gStmts: [dynamic]Stmt

@(private)
dbValid :: proc(h: int) -> bool { return h >= 0 && h < len(gDbs) && gDbs[h] != nil }
@(private)
stmtValid :: proc(s: int) -> bool { return s >= 0 && s < len(gStmts) && gStmts[s] != nil }

// A connection handle >= 0, or -1.
dbOpen :: proc(path: string) -> int {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	db: Sqlite3
	if sqlite3_open(cpath, &db) != 0 {
		if db != nil do sqlite3_close(db)
		return -1
	}
	append(&gDbs, db)
	return len(gDbs) - 1
}

dbClose :: proc(h: int) {
	if !dbValid(h) do return
	sqlite3_close(gDbs[h])
	gDbs[h] = nil
}

// The sqlite result code (0 = ok); -1 for a bad handle.
dbExec :: proc(h: int, sql: string) -> int {
	if !dbValid(h) do return -1
	csql := strings.clone_to_cstring(sql, context.temp_allocator)
	return int(sqlite3_exec(gDbs[h], csql, nil, nil, nil))
}

dbError :: proc(h: int) -> [dynamic]u8 {
	out := make([dynamic]u8)
	if !dbValid(h) do return out
	m := string(sqlite3_errmsg(gDbs[h]))
	for i in 0 ..< len(m) do append(&out, m[i])
	return out
}

// A statement handle >= 0, or -1.
stmtPrepare :: proc(h: int, sql: string) -> int {
	if !dbValid(h) do return -1
	csql := strings.clone_to_cstring(sql, context.temp_allocator)
	s: Stmt
	if sqlite3_prepare_v2(gDbs[h], csql, c.int(len(sql)), &s, nil) != 0 do return -1
	append(&gStmts, s)
	return len(gStmts) - 1
}

stmtFinalize :: proc(s: int) {
	if !stmtValid(s) do return
	sqlite3_finalize(gStmts[s])
	gStmts[s] = nil
}

stmtBindInt :: proc(s: int, idx: int, v: int) -> int {
	if !stmtValid(s) do return -1
	return int(sqlite3_bind_int64(gStmts[s], c.int(idx), i64(v)))
}

stmtBindReal :: proc(s: int, idx: int, v: f64) -> int {
	if !stmtValid(s) do return -1
	return int(sqlite3_bind_double(gStmts[s], c.int(idx), v))
}

stmtBindText :: proc(s: int, idx: int, v: string) -> int {
	if !stmtValid(s) do return -1
	cv := strings.clone_to_cstring(v, context.temp_allocator)
	return int(sqlite3_bind_text(gStmts[s], c.int(idx), cv, c.int(len(v)), rawptr(~uintptr(0))))
}

stmtBindNull :: proc(s: int, idx: int) -> int {
	if !stmtValid(s) do return -1
	return int(sqlite3_bind_null(gStmts[s], c.int(idx)))
}

// 100 = a row, 101 = done, else an error code; -1 for a bad handle.
stmtStep :: proc(s: int) -> int {
	if !stmtValid(s) do return -1
	return int(sqlite3_step(gStmts[s]))
}

stmtColumns :: proc(s: int) -> int {
	if !stmtValid(s) do return 0
	return int(sqlite3_column_count(gStmts[s]))
}

// 1 integer, 2 float, 3 text, 4 blob, 5 null.
stmtColumnType :: proc(s: int, col: int) -> int {
	if !stmtValid(s) do return 5
	return int(sqlite3_column_type(gStmts[s], c.int(col)))
}

stmtColumnInt :: proc(s: int, col: int) -> int {
	if !stmtValid(s) do return 0
	return int(sqlite3_column_int64(gStmts[s], c.int(col)))
}

stmtColumnReal :: proc(s: int, col: int) -> f64 {
	if !stmtValid(s) do return 0
	return sqlite3_column_double(gStmts[s], c.int(col))
}

stmtColumnText :: proc(s: int, col: int) -> [dynamic]u8 {
	out := make([dynamic]u8)
	if !stmtValid(s) do return out
	p := sqlite3_column_text(gStmts[s], c.int(col))
	n := int(sqlite3_column_bytes(gStmts[s], c.int(col)))
	if p == nil do return out
	for i in 0 ..< n do append(&out, p[i])
	return out
}
