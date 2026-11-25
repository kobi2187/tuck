// platforms/linux-kmod/tuck_kglue.c — what a Tuck program needs from the
// Linux kernel, and the module's entry points.
//
// The Tuck program is compiled to C with kernel flags (no SSE, no red
// zone, kernel code model) into one object, tuck_nim.o, that never sees a
// kernel header: everything it needs from the kernel comes through the
// plain C functions below. This file is the only one compiled against the
// kernel's headers, by kbuild.
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/printk.h>
#include <linux/bug.h>
#include <linux/hardirq.h>
#include <linux/irqflags.h>
#include <linux/smp.h>
#include <linux/delay.h>
#define TUCK_SIZE_T size_t
#include "tuck_platform.h"

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION(TUCK_MODULE_DESCRIPTION);

// --- memory: the C allocator Nim's runtime calls ----------------------------
// GFP_ATOMIC wherever sleeping is not allowed (an interrupt, a held
// spinlock, interrupts off), GFP_KERNEL elsewhere.
static gfp_t tuck_gfp(void) {
  return (in_atomic() || irqs_disabled()) ? GFP_ATOMIC : GFP_KERNEL;
}
void *malloc(size_t n) { return kmalloc(n ? n : 1, tuck_gfp()); }
void *calloc(size_t a, size_t b) { return kcalloc(a ? a : 1, b ? b : 1, tuck_gfp()); }
void *realloc(void *p, size_t n) { return krealloc(p, n ? n : 1, tuck_gfp()); }
void free(void *p) { kfree(p); }

// --- output: std/console and the runtime's diagnostics go to printk ---------
void tuck_board_puts(const char *s) { printk(KERN_INFO "%s", s); }
void *stderr;
void *stdout;
size_t fwrite(const void *p, size_t size, size_t n, void *stream);
int fflush(void *stream);
void abort(void);
void exit(int code);
size_t fwrite(const void *p, size_t size, size_t n, void *stream) {
  printk(KERN_ERR "%.*s", (int)(size * n), (const char *)p);
  return n;
}
int fflush(void *stream) { return 0; }

// --- failure: a failed runtime check stops the calling thread ---------------
// Never the machine: BUG() oopses the task that hit the check and the
// kernel goes on. There is no exit() in a kernel; Nim's quit() lands here.
__noreturn void tuck_fatal(const char *msg) {
  pr_err("PANIC: %s\n", msg);
  BUG();
}
__noreturn void exit(int code) {
  pr_err("PANIC: exit(%d) from Tuck code\n", code);
  BUG();
}
void abort(void) { tuck_fatal("abort"); }

// --- critical: ---------------------------------------------------------------
// One module-wide spinlock with interrupts off: on a multi-core machine
// masking interrupts on this core alone protects nothing. `critical:` nests,
// a spinlock does not, so the owner core counts its depth.
static DEFINE_SPINLOCK(tuck_big_lock);
static int tuck_owner = -1;
static int tuck_depth;
unsigned int tuck_irq_save(void) {
  unsigned long flags;
  int cpu;
  local_irq_save(flags);
  cpu = smp_processor_id();
  if (READ_ONCE(tuck_owner) == cpu) { tuck_depth++; return (unsigned int)flags; }
  spin_lock(&tuck_big_lock);
  WRITE_ONCE(tuck_owner, cpu);
  return (unsigned int)flags;   /* x86 keeps IF in bit 9: 32 bits hold it */
}
void tuck_irq_restore(unsigned int saved) {
  unsigned long flags = saved;
  if (tuck_depth > 0) { tuck_depth--; local_irq_restore(flags); return; }
  WRITE_ONCE(tuck_owner, -1);
  spin_unlock(&tuck_big_lock);
  local_irq_restore(flags);
}
void tuck_mem_barrier(void) { smp_mb(); }
void tuck_idle(void) { usleep_range(1000, 2000); }
int tuck_bind_count = 0;

// --- entry points --------------------------------------------------------------
// NimMain runs the program's module initialisers; then `main` is the module's
// init: 0 loads it, a negative errno refuses (a positive value is not an
// errno, so it refuses with -EINVAL). `unload`, when the program has one,
// runs at rmmod.
static int __init tuck_module_init(void) {
  int rc;
  NimMain();
  rc = tuck_kmod_init();
  if (rc > 0) {
    pr_err("tuck: main returned %d, not 0 or a negative errno\n", rc);
    return -EINVAL;
  }
  return rc;
}
static void __exit tuck_module_exit(void) { tuck_kmod_exit(); }
module_init(tuck_module_init);
module_exit(tuck_module_exit);
