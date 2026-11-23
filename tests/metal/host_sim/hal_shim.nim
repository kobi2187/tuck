# Host simulation shim for the embedded experiment.
proc ledOn*(): void =
  echo "LED ON"

proc ledOff*(): void =
  echo "LED OFF"

proc delayMs*(ms: int): void =
  discard

proc regWrite*(a: uint32, value: uint32): void =
  echo "REG WRITE ", a, " = ", value

proc regRead*(a: uint32): uint32 =
  return 0

proc buttonPressed*(): bool =
  return false

proc uartHasByte*(): bool =
  return false

proc uartReadByte*(): uint8 =
  return 0

proc uartWriteByte*(b: uint8): void =
  echo "UART TX ", b

proc ledSet*(id: uint8, lit: bool): void =
  if lit: echo "LED ", id, " ON"
  else: echo "LED ", id, " OFF"

proc applyState*(l0: bool, l1: bool): void =
  echo "STATE l0=", l0, " l1=", l1
