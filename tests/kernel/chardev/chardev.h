/* The C half's interface, as plain prototypes: the Tuck program's object
 * includes this, and never a kernel header. */
#ifndef TUCK_CHARDEV_H
#define TUCK_CHARDEV_H
typedef int (*TcReader)(int n);
int tc_register(TcReader cb);   /* 0, or a negative errno */
void tc_unregister(void);
#endif
