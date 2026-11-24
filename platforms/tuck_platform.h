/* platforms/tuck_platform.h — the contract between a compiled Tuck program
 * and the platform glue that hosts it in a kernel (tuck_kglue.c beside each
 * platform). The program calls these; the glue defines them with the
 * kernel's own primitives. Nothing else crosses: the program's object never
 * includes a kernel header. */
#ifndef TUCK_PLATFORM_H
#define TUCK_PLATFORM_H

/* Program -> glue */
void *malloc(TUCK_SIZE_T n);
void *calloc(TUCK_SIZE_T a, TUCK_SIZE_T b);
void *realloc(void *p, TUCK_SIZE_T n);
void free(void *p);
void tuck_board_puts(const char *s);         /* std/console, diagnostics */
void tuck_fatal(const char *msg);            /* a failed runtime check */
unsigned int tuck_irq_save(void);            /* `critical:` enter */
void tuck_irq_restore(unsigned int saved);   /* `critical:` exit */
void tuck_mem_barrier(void);                 /* a full memory barrier */
void tuck_idle(void);                        /* nothing ready: yield */
extern int tuck_bind_count;                  /* lines bound: none in a kernel */

/* Glue -> program (tuck build generates these) */
void NimMain(void);                          /* the program's initialisers */
int tuck_kmod_init(void);                    /* `main`: 0 loads */
void tuck_kmod_exit(void);                   /* `unload`, when declared */

#endif
