# Nim impl module for sys.audio's ALSA playback — twins: alsa_shim.odin and
# alsa_shim.d. The `snd_pcm_t*` stays in this table; Tuck holds a HANDLE and
# hands over interleaved signed 16-bit little-endian frames as bytes. The device
# name is ALSA's own ("default", "hw:0", or "null", which accepts and discards).
{.passL: "-lasound".}

proc snd_pcm_open(pcm: ptr pointer, name: cstring, stream: cint, mode: cint): cint {.importc, cdecl.}
proc snd_pcm_set_params(pcm: pointer, format, access: cint, channels: cuint, rate: cuint,
                        softResample: cint, latencyUs: cuint): cint {.importc, cdecl.}
proc snd_pcm_writei(pcm: pointer, buf: pointer, frames: culong): clong {.importc, cdecl.}
proc snd_pcm_recover(pcm: pointer, err: cint, silent: cint): cint {.importc, cdecl.}
proc snd_pcm_drain(pcm: pointer): cint {.importc, cdecl.}
proc snd_pcm_close(pcm: pointer): cint {.importc, cdecl.}

var gPcms: seq[pointer]

proc valid(h: int): bool = h >= 0 and h < gPcms.len and gPcms[h] != nil

proc pcmOpen*(device: string, rate, channels: int): int =
  ## A playback handle >= 0, or a negative ALSA error code.
  var pcm: pointer
  let rc = snd_pcm_open(addr pcm, device.cstring, 0, 0)
  if rc < 0: return int rc
  # S16_LE = 2, RW_INTERLEAVED = 3, resampling allowed, 100 ms latency
  let sp = snd_pcm_set_params(pcm, 2, 3, cuint(channels), cuint(rate), 1, 100_000)
  if sp < 0:
    discard snd_pcm_close(pcm)
    return int sp
  gPcms.add pcm
  gPcms.len - 1

proc pcmWrite*(h: int, data: seq[uint8], frameBytes: int): int =
  ## Frames accepted; negative on an unrecoverable error.
  if not valid(h) or data.len == 0 or frameBytes <= 0: return 0
  let frames = data.len div frameBytes
  var n = int snd_pcm_writei(gPcms[h], unsafeAddr data[0], culong(frames))
  if n < 0:
    n = int snd_pcm_recover(gPcms[h], cint(n), 1)
    if n < 0: return n
    n = int snd_pcm_writei(gPcms[h], unsafeAddr data[0], culong(frames))
  n

proc pcmDrain*(h: int) =
  if valid(h): discard snd_pcm_drain(gPcms[h])

proc pcmClose*(h: int) =
  if not valid(h): return
  discard snd_pcm_close(gPcms[h])
  gPcms[h] = nil
