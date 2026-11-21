/* Minimal newlib syscall stubs for freestanding. */
#include <sys/types.h>
#include <errno.h>

int _write(int file, char *ptr, int len) { return len; }
int _read(int file, char *ptr, int len) { return 0; }
int _close(int file) { return -1; }
int _lseek(int file, int ptr, int dir) { return 0; }
void *_sbrk(int incr) { return (void *)-1; }
void _exit(int status) { while (1) {} }
int _kill(int pid, int sig) { return -1; }
int _getpid(void) { return 1; }

/* Thread-pointer storage used by Nim's threadvar TLS access.
 * Variant-I ARM TLS: leave 8 bytes of TCB headroom before the variables.
 * The accessor itself lives in semihost.s: the ARM EABI requires
 * __aeabi_read_tp to preserve r1-r3 and r12, and Nim's generated TLS access
 * keeps the GOT offset in r3 across the call. A C version clobbers r3. */
char tuck_tls[1024];

/* newlib fini array */
void _fini(void) { }

/* tuck_semihost_write is in semihost.s (pure asm, avoids register clobbers). */
