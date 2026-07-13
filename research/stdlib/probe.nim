import std/hashes
import std/streams
import std/strutils
import std/os

# 1. Hashes
var h = hash("test")
echo "hash: ", h

# 2. Streams
var s: Stream = nil
echo "Stream is nil: ", s.isNil

# 3. Signals (POSIX and OS Ctrl-C hook)
# For UNIX / POSIX
import posix
var sig = posix.SIGINT
echo "SIGINT: ", sig

# OS Ctrl-C hook
proc ctrlc() {.noconv.} =
  echo "Ctrl-C pressed"
setControlCHook(ctrlc)

# 4. Hex/binary formatting and parsing
echo "Hex of 255: ", toHex(255)
echo "Parsed hex: ", parseHexInt("FF")
echo "Parsed bin: ", parseBinInt("11111111")

# 5. Path canonicalization
# Nim uses os.expandFilename to resolve symlinks and get absolute path (canonical/realpath)
echo "RealPath: ", expandFilename(".")
