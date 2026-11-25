/* The C half's interface: plain prototypes, no DDK header. */
#ifndef TUCK_WINCOUNT_H
#define TUCK_WINCOUNT_H
typedef int (*TcReader)(int n);
int tc_register(TcReader cb);   /* 0, or a negative NTSTATUS */
void tc_unregister(void);
#endif
