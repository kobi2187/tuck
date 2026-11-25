#!/usr/bin/env bash
# Load a Linux kernel module under QEMU and report what it printed.
# Usage: tools/kernel/linux-run.sh MODULE.ko [KERNEL_VERSION]
#   TUCK_KMOD_EXERCISE: shell commands run while the module is loaded
#   (`cat /dev/tuckcount`); their output is printed prefixed `OUT: `.
#   Boots the distribution kernel (/boot/vmlinuz-VER) with a busybox
#   initramfs whose init inserts the module, prints the kernel log lines
#   it produced, removes it, and powers off. Prints `insmod rc: N` and
#   `rmmod rc: N`; the script exits with insmod's status, 124 if QEMU was
#   still running when the window closed.
# Needs qemu-system-x86_64, busybox (static) and cpio; the kernel image must
# match the headers the module was built against.
set -u
KO="$1"
# The kernel the module was built for, from its own vermagic: on a CI runner
# the newest /lib/modules entry can be the runner's kernel, not that one.
KVER="${2:-$(modinfo -F vermagic "$KO" 2>/dev/null | cut -d' ' -f1)}"
KVER="${KVER:-$(ls /lib/modules | sort -V | tail -1)}"
VMLINUZ="/boot/vmlinuz-$KVER"
[ -r "$KO" ] || { echo "!!! no module $KO"; exit 2; }
for t in qemu-system-x86_64 busybox cpio; do
  command -v "$t" >/dev/null || { echo "!!! linux-run needs $t"; exit 2; }
done
[ -r "$VMLINUZ" ] || { echo "!!! no readable $VMLINUZ"; exit 2; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/root/bin" "$WORK/root/proc" "$WORK/root/sys" "$WORK/root/dev"
cp "$(command -v busybox)" "$WORK/root/bin/busybox"
for c in sh insmod rmmod dmesg mount poweroff cat grep echo sleep sed cut head ls; do
  ln -s busybox "$WORK/root/bin/$c"
done
cp "$KO" "$WORK/root/m.ko"
printf '%s\n' "${TUCK_KMOD_EXERCISE:-}" > "$WORK/root/exercise"
cat > "$WORK/root/init" <<'INIT'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
dmesg -n 1
dmesg -c > /dev/null
insmod /m.ko
echo "insmod rc: $?"
sh /exercise 2>&1 | sed 's/^/OUT: /'
dmesg -c | grep -v -e "taints kernel" -e "verification failed" -e "loading out-of-tree" -e "clocksource" -e "tsc:" | sed 's/^\[[^]]*\] */KLOG: /'
rmmod m 2>/dev/null || rmmod "$(cat /proc/modules | cut -d' ' -f1 | head -1)"
echo "rmmod rc: $?"
dmesg -c | grep -v -e "taints kernel" | sed 's/^\[[^]]*\] */KLOG: /'
poweroff -f
INIT
chmod +x "$WORK/root/init"
(cd "$WORK/root" && find . | cpio -o -H newc 2>/dev/null) > "$WORK/initrd"
timeout 60 qemu-system-x86_64 -m 256M -smp 2 -nographic -no-reboot \
  -kernel "$VMLINUZ" -initrd "$WORK/initrd" \
  -append "console=ttyS0 panic=-1 quiet loglevel=1" 2>&1 \
  | tr -d '\r' | grep -a -o -e "KLOG: .*" -e "OUT: .*" -e "insmod rc: [0-9]*" -e "rmmod rc: [0-9]*" > "$WORK/out"
QRC=${PIPESTATUS[0]}
cat "$WORK/out"
[ "$QRC" = 124 ] && { echo "qemu exit: 124 (still running)"; exit 124; }
RC=$(grep -m1 "insmod rc:" "$WORK/out" | awk '{print $3}')
exit "${RC:-1}"
