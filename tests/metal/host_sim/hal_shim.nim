# Host simulation shim for the embedded experiment. On metal (a board build of
# actor_mailbox, roadmap 2.0) the same procs print through the board console
# with fixed strings: no `echo`, which needs Nim's string heap.
when defined(freestanding):
  proc boardPuts(s: cstring) {.importc: "tuck_board_puts".}
  proc ledOn*(): void = boardPuts("LED ON\n")
  proc ledOff*(): void = boardPuts("LED OFF\n")
  proc delayMs*(ms: int): void = discard
  proc regWrite*(a: uint32, value: uint32): void = discard
  proc regRead*(a: uint32): uint32 = 0
  proc buttonPressed*(): bool = false
  proc uartHasByte*(): bool = false
  proc uartReadByte*(): uint8 = 0
  proc uartWriteByte*(b: uint8): void = discard
  proc onOff(lit: bool, yes, no: cstring) =
    ## Two calls, not `boardPuts(if lit: a else: b)`: an if-expression of
    ## string literals is a string temporary, which standalone Nim cannot copy.
    if lit: boardPuts(yes) else: boardPuts(no)
  proc ledSet*(id: uint8, lit: bool): void = onOff(lit, "LED ON\n", "LED OFF\n")
  proc applyState*(l0: bool, l1: bool): void =
    boardPuts("STATE l0=")
    onOff(l0, "true", "false")
    boardPuts(" l1=")
    onOff(l1, "true\n", "false\n")
else:
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
