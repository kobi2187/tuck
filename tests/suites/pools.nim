## Pools (spec §7.2): a fixed number of cells, handed out by handle, read and
## written through it, and — for the DMA case — their address given to an
## extern.
##
## Ruled 2026-09-26 (#45, #42):
##   * `Cells.read {h}` / `Cells.write {h, value}` through the handle;
##   * a cell STARTS ABSENT, so `read` is a `?T`: zeroed storage can never be
##     read as a value that breaks its type's invariant, and a written value
##     is a construction, validated where it is built;
##   * `Cells.addr {h}` gives a cell's bytes to an extern, and only to one
##     (TK-TY08); a pool whose element carries an invariant has no `addr`
##     (TK-TY31), since memory an extern fills cannot be checked.
##   * `Cells.address {h}` gives the cell's address as a u32 for a DMA
##     register (2026-11-24), with the same TK-TY31 rule.
##
## Every runtime fact is asserted on all three backends (`hostRuns`): the
## pool is a runtime structure in each, three separate implementations of
## one behaviour.

import ../harness

proc run*(t: var T) =
  ## Registers the pool checker assertions: operations by handle, a pool's
  ## handle belonging to that pool, and `addr` handed only to an extern.
  # --- read and write through the handle -----------------------------------
  t.src """
type Cell:
  n: int

pool Cells = Cell [count: 2]

fn main() -> int:
  let a = Cells.acquire
  if not a.ok:
    return 90
  let cell = {n: 42} Cell
  Cells.write {h: a.value, value: cell}
  let back = Cells.read {h: a.value}
  if not back.ok:
    return 91
  return back.value.n
"""
  t.hostRuns "a cell written through its handle reads back", 42

  # A cell starts ABSENT — not as zeroed memory posing as a value.
  t.src """
type Cell:
  n: int

pool Cells = Cell [count: 2]

fn main() -> int:
  let a = Cells.acquire
  if not a.ok:
    return 90
  let back = Cells.read {h: a.value}
  if back.ok:
    return 1
  return 7
"""
  t.hostRuns "a cell nothing has written reads absent", 7

  # ...and a cell handed out again starts absent again: what the last holder
  # left is not the new holder's value.
  t.src """
type Cell:
  n: int

pool Cells = Cell [count: 1]

fn main() -> int:
  let a = Cells.acquire
  if not a.ok:
    return 90
  let cell = {n: 5} Cell
  Cells.write {h: a.value, value: cell}
  Cells.release {h: a.value}
  let b = Cells.acquire
  if not b.ok:
    return 91
  let back = Cells.read {h: b.value}
  if back.ok:
    return back.value.n
  return 7
"""
  t.hostRuns "a re-acquired cell is absent again", 7

  # A handle outlives its tenancy: reading through it after release is the
  # misuse `release` already refuses, on every backend.
  t.src """
type Cell:
  n: int

pool Cells = Cell [count: 1]

fn main() -> int:
  let a = Cells.acquire
  if not a.ok:
    return 90
  Cells.release {h: a.value}
  let back = Cells.read {h: a.value}
  if back.ok:
    return 2
  return 3
"""
  t.hostRuns "reading through a released handle stops the program", 1,
             "TUCK POOL"

  # A pool can be larger than 64 cells: the runtimes' occupancy used to be
  # one u64, and nothing checked the count against it.
  t.src """
type Cell:
  n: int

pool Cells = Cell [count: 100]

fn main() -> int:
  var got = 0
  var i = 0
  for i < 101:
    let a = Cells.acquire
    if a.ok:
      got = got + 1
    i = i + 1
  return got - 50
"""
  t.hostRuns "a pool of 100 hands out exactly 100", 50

  # A program may have its own `read`, `write` and `release`: a pool op is
  # its own node, not a call by that name, so it cannot be mistaken for one.
  t.src """
type Cell:
  n: int

pool Cells = Cell [count: 1]

fn read({n: int}) -> int:
  return n + 1

fn write({n: int}) -> int:
  return n * 2

fn main() -> int:
  let a = Cells.acquire
  if not a.ok:
    return 90
  let cell = {n: 3} Cell
  Cells.write {h: a.value, value: cell}
  let back = Cells.read {h: a.value}
  if not back.ok:
    return 91
  return ({n: back.value.n} read) + ({n: 1} write)
"""
  t.hostRuns "a pool op does not meet a user fn of the same name", 6

  # --- what the checker refuses ---------------------------------------------
  t.src """
type Cell:
  n: int

pool Cells = Cell [count: 1]
pool Other = Cell [count: 1]

fn main() -> int:
  let a = Other.acquire
  if not a.ok:
    return 90
  let cell = {n: 3} Cell
  Cells.write {h: a.value, value: cell}
  return 0
"""
  t.badCheck "another pool's handle is refused", "belongs to that pool"

  t.src """
type Cell:
  n: int

pool Cells = Cell [count: 1]

fn main() -> int:
  let a = Cells.acquire
  if not a.ok:
    return 90
  Cells.write {h: a.value}
  return 0
"""
  t.badCheck "a write without its value is refused", "value"

  t.src """
type Cell:
  n: int

pool Cells = Cell [count: 1]

fn main() -> int:
  Cells.release
  return 0
"""
  t.badCheck "a release without its handle is refused", "h"

  # --- addr: a cell's bytes, for an extern only ------------------------------
  t.src """
extern [c, header: "string.h"]:
  fn memset({p: Buf, c: int, n: int})

pool Frames = Array[8, u8] [count: 2]

fn main() -> int:
  let a = Frames.acquire
  if not a.ok:
    return 90
  let p = Frames.addr {h: a.value}
  {p: p, c: 7, n: 8} memset
  let back = Frames.read {h: a.value}
  if not back.ok:
    return 91
  let bytes = back.value
  if bytes[3] == 7:
    return 7
  return 92
"""
  t.hostRuns "an extern fills a cell through its address", 7

  t.src """
pool Frames = Array[8, u8] [count: 2]

fn leak({h: FramesHandle}) -> Buf:
  let p = Frames.addr {h: h}
  return p

fn main() -> int:
  return 0
"""
  t.badCheck "a cell's address is not returned", "TK-TY08"

  # (A plain fn cannot even DECLARE a `Buf` param; a generic one can be handed
  # one, so that is the shape the flow rule has to catch.)
  t.src """
pool Frames = Array[8, u8] [count: 2]

fn keep[T]({p: T}) -> int:
  return 0

fn main() -> int:
  let a = Frames.acquire
  if not a.ok:
    return 90
  let p = Frames.addr {h: a.value}
  return {p: p} keep
"""
  t.badCheck "a cell's address is not given to a plain fn", "TK-TY08"

  t.src """
type Holder:
  p: int

pool Frames = Array[8, u8] [count: 2]

fn main() -> int:
  let a = Frames.acquire
  if not a.ok:
    return 90
  let p = Frames.addr {h: a.value}
  let r = {q: p, n: 1}
  return r.n
"""
  t.badCheck "a cell's address is not stored in a record", "TK-TY08"

  t.src """
type Live:
  n: int
  invariant:
    n > 0

pool Slots = Live [count: 2]

fn main() -> int:
  let a = Slots.acquire
  if not a.ok:
    return 90
  let p = Slots.addr {h: a.value}
  return 0
"""
  t.badCheck "a pool whose element has an invariant has no addr", "TK-TY31"

  # --- address: a cell's address as a NUMBER, for a DMA register -----------
  # (owner ruling 2026-11-24). `addr` stays for externs; `address` is the
  # same cell as a u32 a register takes, as `buffer.address` is, so a pool
  # of blocks is a set of DMA targets written wholly in Tuck.
  t.src """
pool Blocks = Array[512, u8] [count: 2]

fn main() -> int:
  let a = Blocks.acquire
  let b = Blocks.acquire
  if not a.ok:
    return 1
  if not b.ok:
    return 1
  let x = Blocks.address {h: a.value}
  let y = Blocks.address {h: b.value}
  if x % 4 != 0 or y - x != 512 ~u32:
    return 2
  let got = Blocks.read {h: a.value}
  if not got.ok:
    return 3
  Blocks.release {h: a.value}
  Blocks.release {h: b.value}
  return 7
"""
  t.okCheck "a cell's address is a u32 any code may hold"
  t.emits "Nim: address goes through the runtime", "tuckPoolAddress\\("
  t.hostRuns "cells are 512 apart, aligned, and present once handed out", 7

  t.src """
type Live:
  n: int
  invariant:
    n > 0

pool Slots = Live [count: 2]

fn main() -> int:
  let a = Slots.acquire
  if not a.ok:
    return 90
  let x = Slots.address {h: a.value}
  return 0
"""
  t.badCheck "a pool whose element has an invariant has no address",
             "TK-TY31.*has no `address`"

  t.finish()
