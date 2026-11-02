/* THE NIM BACKEND'S SMALL-BLOCK ALLOCATOR.
 *
 * A Tuck program frees every block itself, so malloc/free are the hot path
 * of anything that builds trees, strings or Seqs (callgrind: 30-60% of
 * binary-trees, wordcount, k-nucleotide). glibc's malloc is general; this is
 * not. One reserved address range, a segment per size class: a block's class
 * is (p - base) / SEG, no header, "is this mine?" is a range check, and the
 * free lists are per thread (no lock). Blocks over 4 KB, over-aligned
 * requests and anything allocated before this ran go to glibc, and free()
 * routes by address. Same design as compiler/tuckrt_d/tuck_arena.d and
 * tuckrt/tuck_arena.odin.
 *
 * Linked into release builds only (tuck_mem.nim). Linux; elsewhere the file
 * is empty and glibc/libc serves.
 */
#include <features.h>
#if defined(__linux__) && defined(__GLIBC__)
#define _GNU_SOURCE
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <sys/mman.h>

extern void *__libc_malloc(size_t);
extern void *__libc_calloc(size_t, size_t);
extern void *__libc_realloc(void *, size_t);
extern void __libc_free(void *);
extern void *__libc_memalign(size_t, size_t);

#define SEG ((size_t)256 << 20)
#define NCLASS 24
#define MAXSMALL 4096

static const unsigned short classBytes[NCLASS] = {
    16, 32, 48, 64, 80, 96, 112, 128, 160, 192, 224, 256,
    320, 384, 448, 512, 640, 768, 896, 1024, 1536, 2048, 3072, 4096};

static unsigned char classOf[MAXSMALL / 16 + 1];
static char *base;                    /* 0 until initialised, or if mmap failed */
static char *bump[NCLASS];
static volatile int lock[NCLASS];
static volatile int state;            /* 0 new, 1 initialising, 2 ready */
static __thread void *cache[NCLASS];

static void init(void) {
    int expected = 0;
    if (!__atomic_compare_exchange_n(&state, &expected, 1, 0, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) {
        while (__atomic_load_n(&state, __ATOMIC_ACQUIRE) != 2) {}
        return;
    }
    int c = 0;
    for (size_t i = 0; i < sizeof classOf; i++) {
        while (classBytes[c] < i * 16) c++;
        classOf[i] = (unsigned char)c;
    }
    void *p = mmap(0, SEG * NCLASS, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (p != MAP_FAILED) {
        for (int i = 0; i < NCLASS; i++) bump[i] = (char *)p + (size_t)i * SEG;
        base = (char *)p;
    }
    __atomic_store_n(&state, 2, __ATOMIC_RELEASE);
}

static inline int inArena(const void *p) {
    return (size_t)((const char *)p - base) < SEG * NCLASS && base != 0;
}

static inline void *take(size_t size) {
    int c = classOf[(size + 15) >> 4];
    void *p = cache[c];
    if (p) { cache[c] = *(void **)p; return p; }
    while (__atomic_exchange_n(&lock[c], 1, __ATOMIC_ACQUIRE)) {}
    if (bump[c] + classBytes[c] <= base + (size_t)(c + 1) * SEG) {
        p = bump[c];
        bump[c] += classBytes[c];
    }
    __atomic_store_n(&lock[c], 0, __ATOMIC_RELEASE);
    return p;
}

void *malloc(size_t n) {
    if (__builtin_expect(state != 2, 0)) init();
    if (n > 0 && n <= MAXSMALL && base) {
        void *p = take(n);
        if (p) return p;
    }
    return __libc_malloc(n);
}

void free(void *p) {
    if (!p) return;
    if (inArena(p)) {
        int c = (int)((size_t)((char *)p - base) / SEG);
        *(void **)p = cache[c];
        cache[c] = p;
        return;
    }
    __libc_free(p);
}

void *calloc(size_t a, size_t b) {
    size_t n;
    if (__builtin_mul_overflow(a, b, &n)) { errno = ENOMEM; return 0; }
    if (__builtin_expect(state != 2, 0)) init();
    if (n > 0 && n <= MAXSMALL && base) {
        void *p = take(n);
        if (p) { memset(p, 0, n); return p; }
    }
    return __libc_calloc(a, b);
}

void *realloc(void *p, size_t n) {
    if (!p) return malloc(n);
    if (n == 0) { free(p); return 0; }
    if (inArena(p)) {
        int c = (int)((size_t)((char *)p - base) / SEG);
        size_t cap = classBytes[c];
        if (n <= cap) return p;
        void *q = malloc(n);
        if (!q) return 0;
        memcpy(q, p, cap);
        free(p);
        return q;
    }
    return __libc_realloc(p, n);
}

/* Aligned requests are glibc's; free() routes them by address. */
void *memalign(size_t al, size_t n) { return __libc_memalign(al, n); }
int posix_memalign(void **out, size_t al, size_t n) {
    void *p = __libc_memalign(al, n);
    if (!p) return ENOMEM;
    *out = p;
    return 0;
}
void *aligned_alloc(size_t al, size_t n) { return __libc_memalign(al, n); }
#endif
