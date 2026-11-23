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

/* No TLS: a board build passes --threads:off and nothing overrides it, so
   Nim emits plain globals. (A host `--threads:on` used to land after the
   board's flags, which is why a 1 KB tuck_tls block and an assembly
   __aeabi_read_tp lived here until 2026-11-22.) */

/* newlib fini array */
void _fini(void) { }

/* Console and exit: boards/common/semihosting.c (tuck_board_puts,
   tuck_board_exit), or a real board's own file with the same two functions. */
