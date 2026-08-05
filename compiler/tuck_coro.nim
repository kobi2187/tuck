## compiler/tuck_coro.nim
##
## Coroutine engine for tuck_async: a flattened, minimal vendoring of the five
## arsenal modules Tuck actually uses (minicoro coroutines, scheduler,
## eventloop), taken from /home/kl/prog/arsenal2 (the tree Tuck was built and
## benchmarked against). Arsenal is no longer an external dependency: the
## installed nimble package lagged this tree and lacked waitTimer/VMEM stacks.
##
## Bundled C lives in compiler/vendor/minicoro (MIT, Eduardo Bart), built with
## MCO_USE_VMEM_ALLOCATOR so a coroutine stack is an mmap reservation and only
## touched pages cost RAM — what tuck_async's 1MB TuckStackSize relies on.
## libaco is deliberately NOT vendored: arsenal hardcodes cbMinicoro, so the
## libaco branch was always dead code here.
##
## Upstream: github.com/kobi2187/arsenal — keep edits minimal so this stays
## diffable against it.

import std/deques
import std/nativesockets
import std/options
import std/os
import std/selectors
import std/sets
import std/tables

# ===========================================================================
# from arsenal/minicoro.nim
# ===========================================================================
## minicoro Backend - Portable Coroutine Library
## ==============================================
##
## Bindings to minicoro - a single-header, portable coroutine library.
## Works on all platforms including Windows.
##
## Features:
## - Single header library (easy to integrate)
## - Cross-platform (Windows, Linux, macOS, ARM, RISC-V, WebAssembly)
## - Good performance (~20-50ns context switches)
## - Supports custom allocators
## - Storage system for passing values
##
## Usage:
## - On Unix: uses assembly (x86_64, ARM64, RISC-V) or ucontext fallback
## - On Windows: uses assembly (x86_64) or Windows fibers


# =============================================================================
# Compile minicoro (header-only, needs MINICORO_IMPL defined once)
# =============================================================================

const minicoroPath = currentSourcePath().parentDir() / "vendor" / "minicoro"

# Create a C file that includes minicoro.h with MINICORO_IMPL
# This is the standard way to use header-only libraries
#
# MCO_USE_VMEM_ALLOCATOR: allocate coroutine stacks with raw mmap (POSIX) /
# VirtualAlloc (Windows) instead of calloc. The stack is a virtual reservation
# — physical pages fault in only as the stack is used — so a large nominal
# stack (e.g. 1MB) costs only the RAM a coroutine actually touches. Lets many
# coroutines each reserve a generous stack without committing the memory, and
# removes the small-fixed-stack overflow risk for deep recursion.
{.emit: """
#define MCO_USE_VMEM_ALLOCATOR
#define MINICORO_IMPL
#include "minicoro.h"
""".}

{.passC: "-I" & minicoroPath.}

# =============================================================================
# minicoro Types
# =============================================================================

type
  McoState* {.importc: "mco_state", header: "minicoro.h".} = enum
    ## Coroutine states
    MCO_DEAD = 0      ## Finished or uninitialized
    MCO_NORMAL = 1    ## Active but not running (resumed another)
    MCO_RUNNING = 2   ## Currently executing
    MCO_SUSPENDED = 3 ## Suspended (yielded or not started)

  McoResult* {.importc: "mco_result", header: "minicoro.h".} = enum
    ## Result codes from minicoro operations
    MCO_SUCCESS = 0
    MCO_GENERIC_ERROR
    MCO_INVALID_POINTER
    MCO_INVALID_COROUTINE
    MCO_NOT_SUSPENDED
    MCO_NOT_RUNNING
    MCO_MAKE_CONTEXT_ERROR
    MCO_SWITCH_CONTEXT_ERROR
    MCO_NOT_ENOUGH_SPACE
    MCO_OUT_OF_MEMORY
    MCO_INVALID_ARGUMENTS
    MCO_INVALID_OPERATION
    MCO_STACK_OVERFLOW

  McoFunc* = proc(co: ptr McoCoro) {.cdecl.}
    ## Coroutine entry function type

  McoCoro* {.importc: "mco_coro", header: "minicoro.h", incompleteStruct.} = object
    ## Opaque coroutine handle

  McoDesc* {.importc: "mco_desc", header: "minicoro.h".} = object
    ## Coroutine creation descriptor
    `func`*: McoFunc       ## Entry point function
    user_data*: pointer    ## User data pointer
    alloc_cb*: pointer     ## Custom allocator (optional)
    dealloc_cb*: pointer   ## Custom deallocator (optional)
    allocator_data*: pointer
    storage_size*: csize_t ## Storage buffer size
    coro_size*: csize_t    ## Internal
    stack_size*: csize_t   ## Stack size in bytes

# =============================================================================
# minicoro Functions
# =============================================================================

proc mco_desc_init*(fn: McoFunc, stack_size: csize_t): McoDesc {.cdecl, importc, header: "minicoro.h".}
  ## Initialize a coroutine descriptor.
  ## stack_size: 0 for default (56KB), or custom size

proc mco_create*(out_co: ptr ptr McoCoro, desc: ptr McoDesc): McoResult {.cdecl, importc, header: "minicoro.h".}
  ## Create a new coroutine.
  ## out_co: Output pointer for coroutine handle
  ## desc: Creation parameters
  ## Returns MCO_SUCCESS on success

proc mco_destroy*(co: ptr McoCoro): McoResult {.cdecl, importc, header: "minicoro.h".}
  ## Destroy a coroutine. Must be DEAD or SUSPENDED.

proc mco_resume*(co: ptr McoCoro): McoResult {.cdecl, importc, header: "minicoro.h".}
  ## Resume a suspended coroutine.

proc mco_yield*(co: ptr McoCoro): McoResult {.cdecl, importc, header: "minicoro.h".}
  ## Yield from current coroutine.

proc mco_status*(co: ptr McoCoro): McoState {.cdecl, importc, header: "minicoro.h".}
  ## Get coroutine state.

proc mco_get_user_data*(co: ptr McoCoro): pointer {.cdecl, importc, header: "minicoro.h".}
  ## Get user data set during creation.

proc mco_running*(): ptr McoCoro {.cdecl, importc, header: "minicoro.h".}
  ## Get the currently running coroutine, or nil.

proc mco_result_description*(res: McoResult): cstring {.cdecl, importc, header: "minicoro.h".}
  ## Get description string for a result code.

# Storage API for passing data between yield/resume
proc mco_push*(co: ptr McoCoro, src: pointer, len: csize_t): McoResult {.cdecl, importc, header: "minicoro.h".}
proc mco_pop*(co: ptr McoCoro, dest: pointer, len: csize_t): McoResult {.cdecl, importc, header: "minicoro.h".}
proc mco_peek*(co: ptr McoCoro, dest: pointer, len: csize_t): McoResult {.cdecl, importc, header: "minicoro.h".}
proc mco_get_bytes_stored*(co: ptr McoCoro): csize_t {.cdecl, importc, header: "minicoro.h".}

# =============================================================================
# Nim Helper Functions
# =============================================================================

proc isDead*(co: ptr McoCoro): bool {.inline.} =
  mco_status(co) == MCO_DEAD

proc isSuspended*(co: ptr McoCoro): bool {.inline.} =
  mco_status(co) == MCO_SUSPENDED

proc isRunning*(co: ptr McoCoro): bool {.inline.} =
  mco_status(co) == MCO_RUNNING

proc checkResult*(res: McoResult) {.inline.} =
  ## Raise exception on error
  if res != MCO_SUCCESS:
    raise newException(CatchableError, "minicoro error: " & $mco_result_description(res))

template mcoYield*() =
  ## Yield from current coroutine (convenience)
  discard mco_yield(mco_running())

# ===========================================================================
# from arsenal/backend.nim
# ===========================================================================
## Coroutine Backend Dispatcher
## ============================



# =============================================================================
# Backend Selection
# =============================================================================

type
  CoroutineBackendKind* = enum
    cbLibaco
    cbMinicoro

const SelectedBackend* = cbMinicoro

const
  # Stack sizes
  DefaultStackSize* = 256 * 1024  ## 256KB default stack
  MinStackSize* = 2 * 1024       ## 2KB minimum
  MaxStackSize* = 8 * 1024 * 1024  ## 8MB maximum

# =============================================================================
# Unified Backend Type
# =============================================================================

type
  UnifiedBackend* = object
    ## Wraps the selected backend implementation
    when SelectedBackend == cbLibaco:
      handle*: ptr AcoHandle
      stack*: ptr AcoShareStack
    else:
      handle*: ptr McoCoro
      desc*: McoDesc

# =============================================================================
# Global State
# =============================================================================

var
  mainCo {.threadvar.}: UnifiedBackend
  backendInitialized {.threadvar.}: bool
  # libaco's shared stack is gone with the backend — only minicoro is vendored.

# =============================================================================
# Backend Operations
# =============================================================================

proc initBackend*() =
  ## Initialize coroutine backend for current thread.
  if backendInitialized: return
  
  when SelectedBackend == cbLibaco:
    aco_thread_init(nil)
    mainCo.handle = aco_create(nil, nil, 0, nil, nil)
    # mainCo.stack is nil for main coroutine
    # Create the shared stack once per thread
    libacoSharedStack = aco_share_stack_new(DefaultStackSize.csize_t)
    
  else:
    # minicoro doesn't need explicit thread init, but we can set up main context if needed
    discard
  
  backendInitialized = true

proc createBackend*(fn: pointer, stackSize: int, userData: pointer): UnifiedBackend =
  ## Create a new coroutine backend
  if not backendInitialized:
    initBackend()

  when SelectedBackend == cbLibaco:
    if mainCo.handle == nil:
      stderr.writeLine("FATAL: mainCo.handle is nil in createBackend")
      quit(1)
      
    # Use the thread-local shared stack
    # Note: We ignore stackSize argument for now and use default shared stack size
    # If custom stack size is needed, we'd need multiple shared stacks or a pool
    result.stack = libacoSharedStack
    
    # Create coroutine
    # Note: fn must be AcoFuncPtr compatible
    result.handle = aco_create(
      mainCo.handle,
      result.stack,
      0,
      cast[AcoFuncPtr](fn),
      userData
    )
  else:
    var desc = mco_desc_init(cast[McoFunc](fn), stackSize.csize_t)
    desc.user_data = userData
    
    let res = mco_create(addr result.handle, addr desc)
    if res != MCO_SUCCESS:
      raise newException(ValueError, "Failed to create minicoro coroutine: " & $res)

proc resume*(backend: UnifiedBackend) {.raises: [].} =
  when SelectedBackend == cbLibaco:
    aco_resume(backend.handle)
  else:
    let res = mco_resume(backend.handle)
    if res != MCO_SUCCESS:
      # A failed switch means the coroutine or its stack is corrupt; there is
      # nothing to recover to. Trapping keeps this proc non-raising, which is
      # what stops Nim threading an error flag through every switch.
      quit("tuck: failed to resume coroutine (minicoro error " & $res & ")")

proc yieldBackend*() =
  when SelectedBackend == cbLibaco:
    aco_yield()
  else:
    mcoYield()

proc exitBackend*() =
  ## Exit the current coroutine (called when function finishes)
  when SelectedBackend == cbLibaco:
    aco_exit()
  else:
    # minicoro doesn't need explicit exit, just return
    discard

proc destroy*(backend: var UnifiedBackend) =
  when SelectedBackend == cbLibaco:
    if backend.handle != nil and backend.handle != mainCo.handle:
      aco_destroy(backend.handle)
      backend.handle = nil
    # Do NOT destroy shared stack here, it is reused
    backend.stack = nil
  else:
    if backend.handle != nil:
      discard mco_destroy(backend.handle)
      backend.handle = nil

proc isFinished*(backend: UnifiedBackend): bool {.inline.} =
  when SelectedBackend == cbLibaco:
    isEnded(backend.handle)
  else:
    isDead(backend.handle)

proc getUserData*(backend: UnifiedBackend): pointer {.inline.} =
  when SelectedBackend == cbLibaco:
    getArg(backend.handle)
  else:
    mco_get_user_data(backend.handle)

# ===========================================================================
# from arsenal/coroutine.nim
# ===========================================================================
## Coroutine - Lightweight Cooperative Threading
## =============================================
##
## Coroutines are lightweight, cooperatively-scheduled execution contexts.
## Unlike OS threads, coroutines:
## - Have tiny stacks (2-64KB vs 1-8MB for threads)
## - Switch in ~10-50ns (vs ~1-10µs for threads)
## - Don't require kernel involvement
## - Must explicitly yield control
##
## Arsenal provides multiple backends:
## - libaco: Best performance on x86_64/ARM64 (Unix)
## - minicoro: Portable fallback for Windows and others
## - (Future) Pure Nim implementation using inline ASM
##
## Usage:
## ```nim
## # Create a coroutine
## let coro = newCoroutine(proc() =
##   echo "Hello from coroutine!"
##   coroYield()  # Suspend execution
##   echo "Resumed!"
## )
##
## coro.resume()  # Prints "Hello from coroutine!"
## coro.resume()  # Prints "Resumed!"
## # Coroutine is now finished
## ```


{.push stackTrace: off.}

type
  CoroutineState* = enum
    ## Current state of a coroutine.
    csReady       ## Created but never resumed
    csRunning     ## Currently executing
    csSuspended   ## Yielded, waiting to be resumed
    csFinished    ## Execution completed

  CoroutineError* = object of CatchableError
    ## Error raised when coroutine operations fail.

  CoroutineProc* = proc() {.closure, gcsafe.}
    ## The type of procedure a coroutine executes.
    ## Must be a closure (captures environment) and GC-safe.

  CoroutineObj = object
    ## Internal coroutine object
    state*: CoroutineState
    entryPoint: CoroutineProc
    backend: UnifiedBackend

proc `=destroy`*(c: var CoroutineObj) =
  ## Destructor - clean up backend resources.
  if c.backend.handle != nil:
    destroy(c.backend)

type
  Coroutine* = ref CoroutineObj
    ## High-level coroutine wrapper providing a safe interface.
    ## Automatically manages the underlying backend.
  
# =============================================================================
# Error Helpers
# =============================================================================

proc raiseCoroutineError(msg: string) {.noinline, noreturn, stackTrace: off.} =
  var e: ref CoroutineError
  new(e)
  e.msg = msg
  raise e

# =============================================================================
# Current Coroutine (Thread Local)
# =============================================================================

var activeCoroutine {.threadvar.}: ptr CoroutineObj
  ## The currently running coroutine in this thread, or nil in main context.
  ## Renamed from arsenal's `currentCoroutine`: flattening put it in the same
  ## scope as scheduler.nim's exported `currentCoroutine()` proc, a different
  ## thing (the scheduler's own view) that must keep its name.
  ##
  ## A RAW POINTER, not a ref, and that is a deliberate ARC decision. As a ref
  ## every read compiled to an `eqcopy` CALL plus an error-flag branch in the
  ## generated C — twice per context switch, on the hottest path there is.
  ##
  ## Safe because this is a VIEW, never an owner: a running coroutine is kept
  ## alive by `resume`'s own `c` parameter (a ref held for the whole call,
  ## including across the switch), and by the scheduler's readyQueue /
  ## currentCoro. activeCoroutine is only ever set to a coroutine that one of
  ## those already owns, and cleared before that owner releases it.

proc running*(): Coroutine =
  ## Get the currently running coroutine, or nil if not in a coroutine.
  ## Converts the view back to a ref for callers, which re-establishes
  ## ownership for as long as they hold it.
  if activeCoroutine == nil: nil
  else: cast[Coroutine](activeCoroutine)

proc inCoroutine*(): bool =
  ## Check if currently executing within a coroutine.
  activeCoroutine != nil

# =============================================================================
# Trampoline (C -> Nim bridge)
# =============================================================================

when SelectedBackend == cbLibaco:
  proc trampoline() {.cdecl, stackTrace: off.} =
    ## Trampoline for libaco (no args, get arg from context)
    let co = aco_get_co()
    let arg = getArg(co)
    let coro = cast[ptr CoroutineObj](arg)
    
    try:
      coro[].entryPoint()
    except CatchableError as e:
      stderr.writeLine("Error in coroutine: " & e.msg)
    finally:
      coro[].state = csFinished
      exitBackend()

else:
  proc trampoline(co: ptr McoCoro) {.cdecl, stackTrace: off.} =
    ## Trampoline for minicoro (takes coroutine pointer)
    let arg = mco_get_user_data(co)
    let coro = cast[ptr CoroutineObj](arg)
    
    try:
      coro[].entryPoint()
    except CatchableError as e:
      stderr.writeLine("Error in coroutine: " & e.msg)
    finally:
      coro[].state = csFinished
      # minicoro just returns

# =============================================================================
# Coroutine Creation
# =============================================================================

proc newCoroutine*(fn: CoroutineProc, stackSize: int = DefaultStackSize): Coroutine =
  ## Create a new coroutine with the given entry point.
  
  new(result)
  result.state = csReady
  result.entryPoint = fn
  
  # Create backend with trampoline
  # We pass `result` (the Coroutine object) as user data
  result.backend = createBackend(
    cast[pointer](trampoline), 
    stackSize, 
    cast[pointer](result)
  )

proc newCoroutine*(fn: proc() {.nimcall, gcsafe.}, stackSize: int = DefaultStackSize): Coroutine =
  ## Overload for non-closure procedures.
  let closureFn: CoroutineProc = proc() = fn()
  newCoroutine(closureFn, stackSize)

# =============================================================================
# Coroutine Operations
# =============================================================================

proc resume*(c: Coroutine) {.raises: [].} =
  ## Resume execution of a suspended coroutine.
  ##
  ## `{.raises: [].}` for the same reason as coroYield: the error-flag
  ## machinery Nim emits around a possibly-raising proc costs more than the
  ## switch itself. Resuming a finished or already-running coroutine is a
  ## programmer error, so it traps.
  if c.state == csFinished:
    quit("tuck: cannot resume a finished coroutine")
  if c.state == csRunning:
    quit("tuck: coroutine is already running")

  c.state = csRunning

  # The `c` parameter is itself a ref held for the duration of this call, so
  # it keeps the coroutine alive across the switch — activeCoroutine is a
  # convenience view, not an owner.
  let prevCoro = activeCoroutine
  activeCoroutine = cast[ptr CoroutineObj](c)

  # No try/finally: with `raises: []` nothing here can unwind, so the
  # restore below always runs and the guard only costs code size.
  resume(c.backend)

  activeCoroutine = prevCoro
  if isFinished(c.backend):
    c.state = csFinished
  else:
    c.state = csSuspended

proc isFinished*(c: Coroutine): bool {.inline.} = c.state == csFinished
proc isRunning*(c: Coroutine): bool {.inline.} = c.state == csRunning
proc isSuspended*(c: Coroutine): bool {.inline.} = c.state == csSuspended

# =============================================================================
# Yield
# =============================================================================

proc coroYield*() {.stackTrace: off, raises: [].} =
  ## Yield execution back to the caller of `resume()`.
  ##
  ## `{.raises: [].}` is load-bearing, not decoration: without it Nim threads
  ## an error flag through this proc, so the generated C fetches
  ## nimErrorFlag() and branches after every statement — twice per switch, on
  ## the hottest path in the runtime. Yielding outside a coroutine is a
  ## PROGRAMMER error, not a recoverable one, so it traps instead of raising.
  let c = activeCoroutine
  if c == nil:
    # not raiseCoroutineError: raising here is what forces the error-flag
    # machinery into the generated C
    quit("tuck: cannot yield outside a coroutine")

  c.state = csSuspended
  yieldBackend()
  c.state = csRunning

# =============================================================================
# Current Coroutine
# =============================================================================

# Moved to top of file


# =============================================================================
# Cleanup
# =============================================================================

proc destroy*(c: Coroutine) =
  ## Explicitly destroy a coroutine.
  if c.backend.handle != nil:
    destroy(c.backend)
  c.state = csFinished

{.pop.}

# ===========================================================================
# from arsenal/scheduler.nim
# ===========================================================================
## Coroutine Scheduler
## ===================
##
## Simple round-robin scheduler for coroutines.
## Manages the ready queue and handles blocking/waking.


template dbg(args: varargs[untyped]) =
  ## Debug tracing, silent unless compiled with -d:arsenalDebug.
  when defined(arsenalDebug):
    echo args
    flushFile(stdout)

type
  Scheduler* = object
    ## Simple round-robin coroutine scheduler.
    readyQueue: Deque[Coroutine]
    currentCoro: Coroutine

var globalScheduler {.threadvar.}: Scheduler
  ## Thread-local scheduler instance

proc ready*(coro: Coroutine) =
  ## Add a coroutine to the ready queue.
  if coro != nil and not coro.isFinished():
    dbg "[Scheduler] Adding coroutine to readyQueue. New len: ", globalScheduler.readyQueue.len + 1
    globalScheduler.readyQueue.addLast(coro)

proc schedule*(coro: Coroutine) =
  ## Alias for ready - add coroutine to scheduler.
  ready(coro)

proc spawn*(fn: proc() {.closure, gcsafe.}): Coroutine =
  ## Create a new coroutine and add it to the ready queue.
  result = newCoroutine(fn)
  ready(result)

proc runNext*(): bool =
  ## Run the next coroutine in the ready queue.
  ## Returns false if no coroutines are ready.
  if globalScheduler.readyQueue.len == 0:
    return false

  let coro = globalScheduler.readyQueue.popFirst()
  dbg "[Scheduler] Popped coroutine from readyQueue. Remaining len: ", globalScheduler.readyQueue.len
  if coro.isFinished():
    # Skip finished coroutines
    return globalScheduler.readyQueue.len > 0

  globalScheduler.currentCoro = coro
  dbg "[Scheduler] Resuming coroutine..."
  coro.resume()
  dbg "[Scheduler] Coroutine returned/suspended."
  globalScheduler.currentCoro = nil

  # If coroutine suspended (not finished), it will be re-added
  # by whoever wakes it up
  return true

proc runAll*() =
  ## Run all coroutines until none are ready.
  while runNext():
    discard

proc runUntilEmpty*() =
  ## Run scheduler until ready queue is empty.
  runAll()

proc hasPending*(): bool =
  ## Check if there are pending coroutines.
  globalScheduler.readyQueue.len > 0

proc currentCoroutine*(): Coroutine =
  ## Get the currently running coroutine (scheduler context).
  globalScheduler.currentCoro

# ===========================================================================
# from arsenal/eventloop.nim
# ===========================================================================
## Event Loop Foundation
## =====================
##
## Asynchronous I/O event loop that integrates with coroutines.
## Supports epoll (Linux), kqueue (macOS/BSD), IOCP (Windows).
##
## The event loop runs in a dedicated coroutine and processes I/O events,
## resuming coroutines when their I/O operations complete.
##
## Usage:
## ```nim
## let loop = newEventLoop()
##
## # Register a socket for reading
## loop.addRead(socket, coro)
##
## # Run the event loop
## loop.run()
## ```


# `dbg` is already declared above (from arsenal/scheduler.nim); eventloop.nim's
# identical copy is dropped — flattening put both in one scope.

type
  Future*[T] = ref object
    ## Placeholder for async result (simplified for now).
    ## Full implementation would integrate with coroutine system.
    completed*: bool
    value*: T

  IoWaiter* = ref object
    ## A coroutine waiting for I/O.
    coro*: Coroutine
    kind*: EventKind
    isTimer*: bool           ## this waiter is the timeout side of a race
    pairFd*: int = -1         ## the other fd in a read-or-timeout race (-1 none)
    outcome*: ref bool       ## shared: set true if the TIMER won

  EventLoop* = ref object
    ## Central event loop for async I/O operations.
    ## Integrates with coroutine scheduler to resume coroutines
    ## when I/O operations complete.
    ## Uses std/selectors for cross-platform I/O multiplexing.
    stopped*: bool
    selector*: Selector[IoWaiter]  # Nim's selector (epoll/kqueue/IOCP wrapper)
    waiters*: Table[int, IoWaiter]  # fd -> waiting coroutine

  EventKind* = enum
    ## Types of I/O events we can wait for.
    ekRead        ## Readable (data available or connection ready)
    ekWrite       ## Writable (can send data)
    ekAccept      ## Incoming connection (server socket)
    ekConnect     ## Outgoing connection completed
    ekError       ## I/O error occurred

  IoRequest* = object
    ## An I/O operation request.
    ## When registered, the requesting coroutine is suspended
    ## until the operation completes or times out.
    fd*: int           ## File descriptor (socket, pipe, etc.)
    kind*: EventKind   ## What operation we want to monitor
    timeoutMs*: int    ## Timeout in milliseconds (0 = no timeout)

  IoResult* = object
    ## Result of an I/O operation.
    case kind*: EventKind
    of ekRead, ekWrite:
      bytesTransferred*: int  ## How many bytes were read/written
    of ekAccept:
      clientFd*: int          ## Accepted client socket
      clientAddr*: string     ## Client address
    of ekConnect:
      connected*: bool        ## Whether connection succeeded
    of ekError:
      errorCode*: int         ## System error code
      errorMsg*: string       ## Error description

# =============================================================================
# Event Loop Creation
# =============================================================================

proc newEventLoop*(): EventLoop =
  ## Create a new event loop using std/selectors.
  ## This provides cross-platform I/O multiplexing:
  ## - Linux: epoll
  ## - macOS/BSD: kqueue
  ## - Windows: IOCP/select
  result = EventLoop(
    stopped: false,
    selector: newSelector[IoWaiter](),
    waiters: initTable[int, IoWaiter]()
  )

proc destroy*(loop: EventLoop) =
  ## Clean up event loop resources.
  loop.selector.close()
  loop.waiters.clear()

# =============================================================================
# Event Registration
# =============================================================================

proc waitForRead*(loop: EventLoop, fd: int | SocketHandle) =
  ## Register interest in read events and yield current coroutine.
  ## The coroutine will be resumed when the fd is readable.
  let currentCoro = running()
  if currentCoro == nil:
    raise newException(IOError, "waitForRead called outside coroutine")

  # Create waiter
  let waiter = IoWaiter(coro: currentCoro, kind: ekRead)
  let fdInt = fd.int
  loop.waiters[fdInt] = waiter

  dbg "[EventLoop] Registering fd ", fdInt, " for READ..."
  # Register with selector (uses epoll/kqueue/IOCP under the hood)
  loop.selector.registerHandle(fdInt, {Event.Read}, waiter)

  # Yield until I/O is ready
  coroYield()

proc waitForWrite*(loop: EventLoop, fd: int | SocketHandle) =
  ## Register interest in write events and yield current coroutine.
  let currentCoro = running()
  if currentCoro == nil:
    raise newException(IOError, "waitForWrite called outside coroutine")

  let waiter = IoWaiter(coro: currentCoro, kind: ekWrite)
  let fdInt = fd.int
  loop.waiters[fdInt] = waiter

  dbg "[EventLoop] Registering fd ", fdInt, " for WRITE..."
  loop.selector.registerHandle(fdInt, {Event.Write}, waiter)

  coroYield()

proc removeWaiter*(loop: EventLoop, fd: int) =
  ## Remove a waiter for this fd.
  if loop.waiters.hasKey(fd):
    try:
      loop.selector.unregister(fd)
    except:
      discard  # Already unregistered
    loop.waiters.del(fd)

# =============================================================================
# Event Loop Execution
# =============================================================================

proc waitForReadOrTimeout*(loop: EventLoop, fd: int | SocketHandle,
                           timeoutMs: int): bool =
  ## Suspend until `fd` is readable OR `timeoutMs` elapses, whichever first.
  ## Returns true if the fd became readable, false on timeout. Both the fd and
  ## a one-shot selector timer register the current coroutine; whichever fires
  ## resumes it, and runOnce unregisters the loser. All per-waiter state — no
  ## loop globals — so it is correct even if reused.
  let me = running()
  if me == nil:
    raise newException(IOError, "waitForReadOrTimeout called outside coroutine")
  let fdInt = fd.int
  let outcome = new(bool)   # set true by runOnce if the TIMER fired
  let ioWaiter = IoWaiter(coro: me, kind: ekRead, isTimer: false,
                          outcome: outcome)
  loop.waiters[fdInt] = ioWaiter
  loop.selector.registerHandle(fdInt, {Event.Read}, ioWaiter)
  let timerFd = loop.selector.registerTimer(timeoutMs, true, IoWaiter(
    coro: me, kind: ekError, isTimer: true, outcome: outcome))
  # pair them so whichever fires cancels the other
  loop.waiters[timerFd] = loop.selector.getData(timerFd)
  ioWaiter.pairFd = timerFd
  loop.waiters[timerFd].pairFd = fdInt
  coroYield()
  not outcome[]

proc waitTimer*(loop: EventLoop, timeoutMs: int) =
  ## Suspend the current coroutine for `timeoutMs` (a cooperative sleep).
  ## A one-shot selector timer resumes it; runOnce unregisters the timer fd.
  let me = running()
  if me == nil:
    raise newException(IOError, "waitTimer called outside coroutine")
  let timerFd = loop.selector.registerTimer(timeoutMs, true,
                  IoWaiter(coro: me, kind: ekError, isTimer: true))
  loop.waiters[timerFd] = loop.selector.getData(timerFd)
  coroYield()

proc runOnce*(loop: EventLoop, timeoutMs: int = 100): bool =
  ## Process one batch of I/O events. Returns true if any events were processed.
  ## timeoutMs: How long to wait for events (default 100ms)

  # Use std/selectors to wait for I/O events (cross-platform)
  let readyKeys = loop.selector.select(timeoutMs)

  if readyKeys.len == 0:
    return false

  # Resume coroutines that have I/O ready
  var resumed = initHashSet[int]()   # coros already woken this pass (by fd)
  for key in readyKeys:
    let waiter = loop.selector.getData(key.fd)
    let fd = key.fd.int
    dbg "[EventLoop] Event triggered on fd ", fd, " (Events: ", key.events, ")!"

    if waiter == nil:
      dbg "[EventLoop] Warning: Waiter for fd ", fd, " is nil!"
      continue

    # read-or-timeout race: whichever side fires cancels the other, and the
    # timer side records that it won (outcome=true → the caller sees a timeout)
    let pair = waiter.pairFd
    if waiter.outcome != nil:
      waiter.outcome[] = waiter.isTimer
    let coroId = cast[int](waiter.coro)

    # unregister this fd and its pair (the loser)
    for f in [fd, pair]:
      if f >= 0 and loop.waiters.hasKey(f):
        loop.waiters.del(f)
        try: loop.selector.unregister(f)
        except: discard

    # resume the coroutine exactly once
    if coroId notin resumed:
      resumed.incl(coroId)
      ready(waiter.coro)

  return readyKeys.len > 0

proc run*(loop: EventLoop) =
  ## Run the event loop. Processes I/O events and resumes coroutines.
  ## This runs until stop() is called or there are no more waiters.

  loop.stopped = false
  while not loop.stopped:
    # Drain the ready queue FIRST. Blocking in epoll before running work that
    # is already runnable costs the whole timeout on every pass: a spawned
    # coroutine with no pending I/O waited up to 100ms to start, and a program
    # doing N sequential offloads paid it N times (measured: a constant ~100ms
    # on top of every blocking call, independent of how many were queued).
    # The Odin tuckRun always had this order.
    while hasPending():
      discard runNext()

    # Exit before parking if nothing can wake us — otherwise a finished
    # program sits in epoll for the timeout on its way out. Checked AFTER the
    # drain, so a coroutine that called stop() in this pass is honoured
    # immediately rather than after another 100ms in epoll_wait.
    if loop.stopped or (loop.waiters.len == 0 and not hasPending()):
      break

    # Now park for I/O, which is the only thing that can produce more work.
    discard loop.runOnce(timeoutMs = 100)

proc stop*(loop: EventLoop) =
  ## Stop the event loop. Causes run() to return.
  loop.stopped = true

# =============================================================================
# Global Event Loop Instance
# =============================================================================

var globalEventLoop* {.threadvar.}: EventLoop
  ## Thread-local global event loop instance.

proc getEventLoop*(): EventLoop =
  ## Get or create the thread-local event loop.
  if globalEventLoop.isNil:
    globalEventLoop = newEventLoop()
  globalEventLoop

# =============================================================================
# Note on Backend Implementation
# =============================================================================

## This event loop uses std/selectors which provides cross-platform I/O
## multiplexing with the best backend for each platform:
##
## - Linux: epoll (O(1) event retrieval)
## - macOS/BSD: kqueue (high-performance kernel event notification)
## - Windows: IOCP or select fallback
##
## The backends in backends/ directory are kept for reference and
## potential future custom implementations, but we leverage Nim's
## stdlib for production use (high quality, well-tested, cross-platform).
