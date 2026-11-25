// platforms/windows-kmd/tuck_kglue.c — what a Tuck program needs from the
// Windows kernel, and the driver's entry points.
//
// As on Linux, the Tuck program is one object compiled without kernel
// headers; this file is the only one that includes <ntddk.h>. Built with
// mingw-w64 (whose DDK headers and ntoskrnl import library are enough for a
// WDM driver); the WDK's cl.exe would take the same file.
#include <ntddk.h>
#define TUCK_SIZE_T size_t
#include "tuck_platform.h"

#define TUCK_POOL_TAG 0x6B637554u   // "Tuck" in a pool dump (bytes T, u, c, k)

// --- memory: non-paged, so any IRQL may touch it ------------------------------
// Each block carries its size in front, which realloc needs and the pool
// does not keep for us.
typedef struct { SIZE_T size; SIZE_T pad; } TuckBlock;
void *malloc(size_t n) {
  TuckBlock *b = (TuckBlock *)ExAllocatePoolWithTag(NonPagedPool, sizeof(TuckBlock) + (n ? n : 1), TUCK_POOL_TAG);
  if (!b) return NULL;
  b->size = n;
  return b + 1;
}
void free(void *p) {
  if (p) ExFreePoolWithTag((TuckBlock *)p - 1, TUCK_POOL_TAG);
}
void *calloc(size_t a, size_t b) {
  size_t n = a * b;
  void *p = malloc(n);
  if (p) RtlZeroMemory(p, n);
  return p;
}
void *realloc(void *p, size_t n) {
  void *q;
  if (!p) return malloc(n);
  q = malloc(n);
  if (!q) return NULL;
  RtlCopyMemory(q, p, ((TuckBlock *)p - 1)->size < n ? ((TuckBlock *)p - 1)->size : n);
  free(p);
  return q;
}

// --- output: std/console and diagnostics go to the debugger (DbgView, WinDbg)
void tuck_board_puts(const char *s) { DbgPrint("%s", s); }
void *stderr;
void *stdout;
size_t fwrite(const void *p, size_t size, size_t n, void *stream);
int fflush(void *stream);
size_t fwrite(const void *p, size_t size, size_t n, void *stream) {
  DbgPrint("%.*s", (int)(size * n), (const char *)p);
  return n;
}
int fflush(void *stream) { return 0; }

// --- failure: a kernel has no exit, so a failed check is a bug check ----------
#define TUCK_BUGCHECK 0x54554B43   // 'TUCK'
__declspec(noreturn) void tuck_fatal(const char *msg) {
  DbgPrint("PANIC: %s\n", msg);
  KeBugCheckEx(TUCK_BUGCHECK, (ULONG_PTR)msg, 0, 0, 0);
}
__declspec(noreturn) void exit(int code);
__declspec(noreturn) void exit(int code) {
  DbgPrint("PANIC: exit(%d) from Tuck code\n", code);
  KeBugCheckEx(TUCK_BUGCHECK, 1, (ULONG_PTR)code, 0, 0);
}
void abort(void);
void abort(void) { tuck_fatal("abort"); }

// --- critical: ------------------------------------------------------------------
// HIGH_LEVEL masks every interrupt on this processor; an owner word spun on
// with interlocked operations excludes the others. `critical:` nests, so the
// owning processor counts its depth.
static volatile LONG tuck_owner = -1;
static int tuck_depth;
unsigned int tuck_irq_save(void) {
  KIRQL old;
  LONG cpu;
  KeRaiseIrql(HIGH_LEVEL, &old);
  cpu = (LONG)KeGetCurrentProcessorNumberEx(NULL);
  if (tuck_owner == cpu) { tuck_depth++; return old; }
  while (InterlockedCompareExchange(&tuck_owner, cpu, -1) != -1) YieldProcessor();
  return old;
}
void tuck_irq_restore(unsigned int saved) {
  if (tuck_depth > 0) { tuck_depth--; KeLowerIrql((KIRQL)saved); return; }
  InterlockedExchange(&tuck_owner, -1);
  KeLowerIrql((KIRQL)saved);
}
#if defined(__GNUC__)
void tuck_mem_barrier(void) { __sync_synchronize(); }   // mfence on x64
#else
void tuck_mem_barrier(void) { MemoryBarrier(); }
#endif
void tuck_idle(void) {
  LARGE_INTEGER t;
  t.QuadPart = -10000;   // 1 ms, relative
  KeDelayExecutionThread(KernelMode, FALSE, &t);
}
int tuck_bind_count = 0;

// --- entry points --------------------------------------------------------------
// `main` is DriverEntry's body: 0 loads the driver; a negative value is taken
// as the NTSTATUS to fail with (they have the high bit set); a positive one
// fails with STATUS_UNSUCCESSFUL. `unload`, when the program has one, runs
// when the driver is unloaded.
// The driver object, for the program's own C (`extern [c, lib: "x.c"]`):
// creating a device or setting dispatch routines needs it.
PDRIVER_OBJECT tuck_driver_object;

static VOID tuck_driver_unload(PDRIVER_OBJECT d) {
  UNREFERENCED_PARAMETER(d);
  tuck_kmod_exit();
}
NTSTATUS DriverEntry(PDRIVER_OBJECT d, PUNICODE_STRING path);
NTSTATUS DriverEntry(PDRIVER_OBJECT d, PUNICODE_STRING path) {
  int rc;
  UNREFERENCED_PARAMETER(path);
  tuck_driver_object = d;
  d->DriverUnload = tuck_driver_unload;
  NimMain();
  rc = tuck_kmod_init();
  if (rc == 0) return STATUS_SUCCESS;
  return rc < 0 ? (NTSTATUS)rc : STATUS_UNSUCCESSFUL;
}
