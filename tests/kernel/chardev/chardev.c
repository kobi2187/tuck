// The kernel half of tuckcount.tuck: a misc character device, /dev/tuckcount.
// Each read asks the Tuck program what to answer for the n-th read and
// returns that number as a line. Compiled by kbuild against the kernel's
// headers (the program's own object never sees them).
#include <linux/module.h>
#include <linux/miscdevice.h>
#include <linux/fs.h>
#include <linux/atomic.h>
#include "chardev.h"

static TcReader tc_cb;
static atomic_t tc_reads = ATOMIC_INIT(0);

static ssize_t tc_read(struct file *f, char __user *buf, size_t len, loff_t *off) {
  char line[24];
  int n;
  if (*off > 0) return 0;          /* one line per open */
  n = snprintf(line, sizeof line, "%d\n", tc_cb(atomic_inc_return(&tc_reads)));
  return simple_read_from_buffer(buf, len, off, line, n);
}

static const struct file_operations tc_fops = { .owner = THIS_MODULE, .read = tc_read };
static struct miscdevice tc_dev = { .minor = MISC_DYNAMIC_MINOR, .name = "tuckcount",
                                    .fops = &tc_fops, .mode = 0444 };

int tc_register(TcReader cb) { tc_cb = cb; return misc_register(&tc_dev); }
void tc_unregister(void) { misc_deregister(&tc_dev); }
