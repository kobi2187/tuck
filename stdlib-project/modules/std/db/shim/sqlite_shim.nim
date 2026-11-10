# Nim impl module for stdlib-project std.db's sqlite3 driver — the twins are
# sqlite_shim.odin and sqlite_shim.d, beside this file.
#
# A `sqlite3*` and a `sqlite3_stmt*` may not be held by Tuck (no stored
# pointers), so they stay in these tables and Tuck holds HANDLES, indexes into
# them. Text comes back as bytes (`Seq[u8]`), the way sys.mmap hands bytes over.
# The tables are process-global and not locked: a connection is used from the
# thread that opened it, as the runtime's other handles are.
{.passL: "-lsqlite3".}

type
  Sqlite3 = pointer
  Stmt = pointer

proc sqlite3_open(path: cstring, db: ptr Sqlite3): cint {.importc, cdecl.}
proc sqlite3_close(db: Sqlite3): cint {.importc, cdecl.}
proc sqlite3_exec(db: Sqlite3, sql: cstring, cb: pointer, arg: pointer,
                  err: pointer): cint {.importc, cdecl.}
proc sqlite3_prepare_v2(db: Sqlite3, sql: cstring, n: cint, s: ptr Stmt,
                        tail: pointer): cint {.importc, cdecl.}
proc sqlite3_finalize(s: Stmt): cint {.importc, cdecl.}
proc sqlite3_step(s: Stmt): cint {.importc, cdecl.}
proc sqlite3_bind_int64(s: Stmt, i: cint, v: int64): cint {.importc, cdecl.}
proc sqlite3_bind_double(s: Stmt, i: cint, v: cdouble): cint {.importc, cdecl.}
proc sqlite3_bind_text(s: Stmt, i: cint, v: cstring, n: cint, d: pointer): cint {.importc, cdecl.}
proc sqlite3_bind_null(s: Stmt, i: cint): cint {.importc, cdecl.}
proc sqlite3_column_count(s: Stmt): cint {.importc, cdecl.}
proc sqlite3_column_type(s: Stmt, i: cint): cint {.importc, cdecl.}
proc sqlite3_column_int64(s: Stmt, i: cint): int64 {.importc, cdecl.}
proc sqlite3_column_double(s: Stmt, i: cint): cdouble {.importc, cdecl.}
proc sqlite3_column_text(s: Stmt, i: cint): cstring {.importc, cdecl.}
proc sqlite3_column_bytes(s: Stmt, i: cint): cint {.importc, cdecl.}
proc sqlite3_errmsg(db: Sqlite3): cstring {.importc, cdecl.}

var gDbs: seq[Sqlite3]
var gStmts: seq[Stmt]
var gStmtDb: seq[int]

proc dbOpen*(path: string): int =
  ## A connection handle >= 0, or -1.
  var db: Sqlite3
  if sqlite3_open(path.cstring, addr db) != 0:
    if db != nil: discard sqlite3_close(db)
    return -1
  gDbs.add db
  gDbs.len - 1

proc dbValid(h: int): bool = h >= 0 and h < gDbs.len and gDbs[h] != nil

proc dbClose*(h: int) =
  if not dbValid(h): return
  discard sqlite3_close(gDbs[h])
  gDbs[h] = nil

proc dbExec*(h: int, sql: string): int =
  ## The sqlite result code (0 = ok); -1 for a bad handle.
  if not dbValid(h): return -1
  int sqlite3_exec(gDbs[h], sql.cstring, nil, nil, nil)

proc dbError*(h: int): seq[uint8] =
  if not dbValid(h): return @[]
  let m = sqlite3_errmsg(gDbs[h])
  for c in $m: result.add uint8(c)

proc stmtValid(s: int): bool = s >= 0 and s < gStmts.len and gStmts[s] != nil

proc stmtPrepare*(h: int, sql: string): int =
  ## A statement handle >= 0, or -1.
  if not dbValid(h): return -1
  var s: Stmt
  if sqlite3_prepare_v2(gDbs[h], sql.cstring, cint(sql.len), addr s, nil) != 0:
    return -1
  gStmts.add s
  gStmtDb.add h
  gStmts.len - 1

proc stmtFinalize*(s: int) =
  if not stmtValid(s): return
  discard sqlite3_finalize(gStmts[s])
  gStmts[s] = nil

proc stmtBindInt*(s, idx, v: int): int =
  if not stmtValid(s): return -1
  int sqlite3_bind_int64(gStmts[s], cint(idx), int64(v))

proc stmtBindReal*(s, idx: int, v: float): int =
  if not stmtValid(s): return -1
  int sqlite3_bind_double(gStmts[s], cint(idx), cdouble(v))

proc stmtBindText*(s, idx: int, v: string): int =
  if not stmtValid(s): return -1
  int sqlite3_bind_text(gStmts[s], cint(idx), v.cstring, cint(v.len), cast[pointer](-1))

proc stmtBindNull*(s, idx: int): int =
  if not stmtValid(s): return -1
  int sqlite3_bind_null(gStmts[s], cint(idx))

proc stmtStep*(s: int): int =
  ## 100 = a row, 101 = done, else an error code; -1 for a bad handle.
  if not stmtValid(s): return -1
  int sqlite3_step(gStmts[s])

proc stmtColumns*(s: int): int =
  if not stmtValid(s): return 0
  int sqlite3_column_count(gStmts[s])

proc stmtColumnType*(s, col: int): int =
  ## 1 integer, 2 float, 3 text, 4 blob, 5 null.
  if not stmtValid(s): return 5
  int sqlite3_column_type(gStmts[s], cint(col))

proc stmtColumnInt*(s, col: int): int =
  if not stmtValid(s): return 0
  int sqlite3_column_int64(gStmts[s], cint(col))

proc stmtColumnReal*(s, col: int): float =
  if not stmtValid(s): return 0.0
  float sqlite3_column_double(gStmts[s], cint(col))

proc stmtColumnText*(s, col: int): seq[uint8] =
  if not stmtValid(s): return @[]
  let p = sqlite3_column_text(gStmts[s], cint(col))
  let n = int sqlite3_column_bytes(gStmts[s], cint(col))
  if p == nil: return @[]
  let a = cast[ptr UncheckedArray[uint8]](p)
  for i in 0 ..< n: result.add a[i]
