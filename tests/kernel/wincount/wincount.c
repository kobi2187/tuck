// The kernel half of wincount.tuck: a WDM device, \Device\TuckCount (and
// \DosDevices\TuckCount for user mode). Each read asks the Tuck program what
// to answer for the n-th read and returns it as a line. Compiled against the
// DDK headers by `tuck build --target:windows-kmd`, beside the platform glue,
// which owns DriverEntry; this file reaches the driver object through it.
#include <ntddk.h>
#include "wincount.h"

extern PDRIVER_OBJECT tuck_driver_object;   // platforms/windows-kmd/tuck_kglue.c

static TcReader tc_cb;
static LONG tc_reads;
static PDEVICE_OBJECT tc_device;
static UNICODE_STRING tc_link;

static NTSTATUS tc_complete(PIRP irp, NTSTATUS st, ULONG_PTR n) {
  irp->IoStatus.Status = st;
  irp->IoStatus.Information = n;
  IoCompleteRequest(irp, IO_NO_INCREMENT);
  return st;
}
static NTSTATUS tc_open_close(PDEVICE_OBJECT d, PIRP irp) {
  UNREFERENCED_PARAMETER(d);
  return tc_complete(irp, STATUS_SUCCESS, 0);
}
static NTSTATUS tc_read(PDEVICE_OBJECT d, PIRP irp) {
  PIO_STACK_LOCATION sl = IoGetCurrentIrpStackLocation(irp);
  char line[24];
  int v = tc_cb(InterlockedIncrement(&tc_reads));
  int n = 0, i;
  char rev[16];
  int neg = v < 0;
  unsigned int u = neg ? 0u - (unsigned int)v : (unsigned int)v;
  UNREFERENCED_PARAMETER(d);
  do { rev[n++] = (char)('0' + u % 10); u /= 10; } while (u && n < 15);
  i = 0;
  if (neg) line[i++] = '-';
  while (n) line[i++] = rev[--n];
  line[i++] = '\n';
  if (sl->Parameters.Read.Length < (ULONG)i || !irp->AssociatedIrp.SystemBuffer)
    return tc_complete(irp, STATUS_BUFFER_TOO_SMALL, 0);
  RtlCopyMemory(irp->AssociatedIrp.SystemBuffer, line, i);
  return tc_complete(irp, STATUS_SUCCESS, i);
}

int tc_register(TcReader cb) {
  UNICODE_STRING name;
  NTSTATUS st;
  tc_cb = cb;
  RtlInitUnicodeString(&name, L"\\Device\\TuckCount");
  RtlInitUnicodeString(&tc_link, L"\\DosDevices\\TuckCount");
  st = IoCreateDevice(tuck_driver_object, 0, &name, FILE_DEVICE_UNKNOWN, 0, FALSE, &tc_device);
  if (!NT_SUCCESS(st)) return (int)st;
  tc_device->Flags |= DO_BUFFERED_IO;
  tuck_driver_object->MajorFunction[IRP_MJ_CREATE] = tc_open_close;
  tuck_driver_object->MajorFunction[IRP_MJ_CLOSE] = tc_open_close;
  tuck_driver_object->MajorFunction[IRP_MJ_READ] = tc_read;
  st = IoCreateSymbolicLink(&tc_link, &name);
  if (!NT_SUCCESS(st)) { IoDeleteDevice(tc_device); return (int)st; }
  return 0;
}
void tc_unregister(void) {
  IoDeleteSymbolicLink(&tc_link);
  IoDeleteDevice(tc_device);
}
