#!/bin/sh
# Run a command and FAIL if its peak resident memory exceeds a budget.
#
# Nothing else in the suite measures memory, which is how a backend that
# never frees a heap value passed every assertion while leaking 75 KB per
# message (KNOWN-BUGS-EVENTS.md EV-12). An allocation bug is invisible to
# `okCheck`, to a regex over emitted text, and to an exit code — it shows up
# only as a number that grows.
#
# Usage: peak_rss.sh <budgetKB> <command> [args...]
#   exit 0  -> the command succeeded AND stayed under budget
#   exit 90 -> the command succeeded but exceeded it
#   other   -> the command's own exit code, unchanged
#
# VmHWM is the kernel's own high-water mark, so sampling cannot UNDER-report
# a peak that has already happened — only miss one that occurs entirely
# between two samples of a process we have stopped watching. At 10 ms and
# against budgets in the tens of megabytes that does not matter: allocating
# enough to blow one of these takes far longer than a sample interval.
budget=$1
shift
[ -z "$budget" ] && { echo "peak_rss.sh: no budget given" >&2; exit 2; }

"$@" &
pid=$!
peak=0
while kill -0 "$pid" 2>/dev/null; do
  cur=$(awk '/VmHWM/{print $2}' "/proc/$pid/status" 2>/dev/null)
  if [ -n "$cur" ] && [ "$cur" -gt "$peak" ]; then peak=$cur; fi
  sleep 0.01
done
wait "$pid"
rc=$?

echo "peakRSS=${peak}KB budget=${budget}KB"
# The command's own failure is reported as the command's failure. A test that
# blamed a crash on memory would send the reader to the wrong place.
[ "$rc" -ne 0 ] && exit "$rc"
# Never sampled: the process finished inside one interval. That bounds it far
# below any budget worth asserting, so it is a pass, not an unknown.
[ "$peak" -gt "$budget" ] && exit 90
exit 0
