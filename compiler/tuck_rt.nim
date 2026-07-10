# compiler/tuck_rt.nim
## Shared Tuck compiler runtime implementation for static environments.
import std/macros

type
  AccessMode* = enum
    ReadOnly, WriteOnly, ReadWrite

macro registerMMIO*(name: untyped, address: static[int], body: untyped): untyped =
  result = newStmtList()
  
  # Generate: type name* = ref object
  let typeSection = newTree(nnkTypeSection,
    newTree(nnkTypeDef,
      postfix(name, "*"),
      newEmptyNode(),
      newTree(nnkRefTy, newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), newEmptyNode()))
    )
  )
  result.add(typeSection)
  
  for child in body:
    if child.kind in {nnkCall, nnkCommand} and child.len >= 2:
      let fieldName = child[0]
      let bitCall = child[1]
      if bitCall.kind == nnkCall and bitCall.len >= 3:
        let bitIndex = bitCall[1]
        let modeName = bitCall[2].repr
        
        # Getter
        let getterNode = quote do:
          proc `fieldName`*(): bool {.inline.} =
            let p = cast[ptr uint32](`address`)
            return (p[] and (1'u32 shl `bitIndex`)) != 0
        result.add(getterNode)
        
        # Setter
        if modeName == "ReadWrite" or modeName == "WriteOnly":
          let setterNameNode = newIdentNode("`" & fieldName.repr & "=`")
          let setterNode = quote do:
            proc `setterNameNode`*(val: bool) {.inline.} =
              let p = cast[ptr uint32](`address`)
              if val:
                p[] = p[] or (1'u32 shl `bitIndex`)
              else:
                p[] = p[] and not(1'u32 shl `bitIndex`)
          result.add(setterNode)

# --- Errors and absence: !T / ?T lower to one value type (no alloc, no nil) ---
# ?T is an option: absence is a first-class state, not a reserved error code.
# !T uses tsOk/tsErr, ?T uses tsOk/tsAbsent, !?T may be any of the three.
type
  TuckStatus* = enum
    tsOk, tsErr, tsAbsent
  TuckResult*[T] = object
    status*: TuckStatus
    err*: uint16   # app-wide error code; meaningful only when status == tsErr
    value*: T

proc errCode*(name: static string): uint16 =
  # compile-time FNV-1a, folded to 16 bits; stable across builds, no tables
  var h = 2166136261'u32
  for c in name:
    h = (h xor uint32(c)) * 16777619'u32
  uint16((h xor (h shr 16)) and 0xFFFF'u32)

proc ok*[T](r: TuckResult[T]): bool {.inline.} = r.status == tsOk

proc tok*[T](v: T): TuckResult[T] {.inline.} =
  TuckResult[T](status: tsOk, value: v)

proc tokVoid*(): TuckResult[tuple[]] {.inline.} =
  TuckResult[tuple[]](status: tsOk)

proc terr*[T](code: uint16): TuckResult[T] {.inline.} =
  TuckResult[T](status: tsErr, err: code)

proc tnone*[T](): TuckResult[T] {.inline.} =
  TuckResult[T](status: tsAbsent)

proc tfwd*[T](status: TuckStatus, err: uint16): TuckResult[T] {.inline.} =
  ## `?` propagation: forward failure OR absence unchanged (status-preserving)
  TuckResult[T](status: status, err: err)

proc tuckReportUnhandled*(code: uint16, site: string) =
  stderr.writeLine("TUCK UNHANDLED: error " & $code & " at " & site)

type
  BumpArena*[Size: static int] = object
    buffer*: array[Size, byte]
    cursor*: int

proc alloc*[Size: static int](arena: var BumpArena[Size], bytes: int): pointer =
  if arena.cursor + bytes > Size:
    raise newException(OutOfMemoryDefect, "Arena buffer exhausted")
  result = addr arena.buffer[arena.cursor]
  arena.cursor += bytes

proc reset*[Size: static int](arena: var BumpArena[Size]) =
  arena.cursor = 0

type
  ObjectPool*[T; Count: static int] = object
    storage*: array[Count, T]
    occupied*: uint64

proc acquire*[T; Count: static int](pool: var ObjectPool[T, Count]): ptr T =
  for i in 0..<Count:
    if (pool.occupied and (1'u64 shl i)) == 0:
      pool.occupied = pool.occupied or (1'u64 shl i)
      return addr pool.storage[i]
  return nil

proc release*[T; Count: static int](pool: var ObjectPool[T, Count], item: ptr T) =
  let baseAddr = cast[int](addr pool.storage[0])
  let itemAddr = cast[int](item)
  let index = (itemAddr - baseAddr) div sizeof(T)
  if index >= 0 and index < Count:
    pool.occupied = pool.occupied and not(1'u64 shl index)

type
  Mailbox*[T; Cap: static int] = object
    data*: array[Cap, T]
    head*: int
    tail*: int

proc enqueue*[T; Cap: static int](mb: var Mailbox[T, Cap], msg: T): bool =
  let next = (mb.tail + 1) mod Cap
  if next == mb.head:
    return false
  mb.data[mb.tail] = msg
  mb.tail = next
  return true

proc dequeue*[T; Cap: static int](mb: var Mailbox[T, Cap], msg: var T): bool =
  if mb.head == mb.tail:
    return false
  msg = mb.data[mb.head]
  mb.head = (mb.head + 1) mod Cap
  return true
