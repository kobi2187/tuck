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

/* Thread-pointer read used by Nim's threadvar TLS access.
 * Variant-I ARM TLS: leave 8 bytes of TCB headroom before the variables. */
static char tuck_tls[1024];
void *__aeabi_read_tp(void) { return tuck_tls + 8; }

/* newlib fini array */
void _fini(void) { }

/* tuck_semihost_write is in semihost.s (pure asm, avoids register clobbers). */
