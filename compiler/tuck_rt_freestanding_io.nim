# compiler/tuck_rt_freestanding_io.nim — std/console on a target with no OS
# streams: a board (semihosting or UART) or a kernel (printk, DbgPrint).
# Included by tuck_rt when `freestanding` is defined. Every line goes to the
# platform's `tuck_board_puts`, which the board's console file or the
# kernel glue defines; there is no input, so `readLine` is absent and a
# program that calls it does not link.

proc tuckPlatformPuts(s: cstring) {.importc: "tuck_board_puts".}

proc print*(text: string) =
  ## Writes `text` with no newline.
  tuckPlatformPuts(cstring(text))

proc printLine*(text: string) =
  ## Writes `text` and a newline, in one call so a kernel log keeps it
  ## as one record.
  tuckPlatformPuts(cstring(text & "\n"))

proc printError*(text: string) =
  ## The same channel: a board or a kernel has one log.
  tuckPlatformPuts(cstring(text & "\n"))
