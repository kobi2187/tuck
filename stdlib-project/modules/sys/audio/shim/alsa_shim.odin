// Odin impl module for sys.audio's ALSA playback — the twin of alsa_shim.nim.
package alsa_shim

import "core:c"
import "core:strings"

foreign import asound "system:asound"

@(default_calling_convention = "c", private)
foreign asound {
	snd_pcm_open :: proc(pcm: ^rawptr, name: cstring, stream: c.int, mode: c.int) -> c.int ---
	snd_pcm_set_params :: proc(pcm: rawptr, format, access: c.int, channels: c.uint, rate: c.uint, soft: c.int, latency: c.uint) -> c.int ---
	snd_pcm_writei :: proc(pcm: rawptr, buf: rawptr, frames: c.ulong) -> c.long ---
	snd_pcm_recover :: proc(pcm: rawptr, err: c.int, silent: c.int) -> c.int ---
	snd_pcm_drain :: proc(pcm: rawptr) -> c.int ---
	snd_pcm_close :: proc(pcm: rawptr) -> c.int ---
}

@(private) gPcms: [dynamic]rawptr

@(private)
valid :: proc(h: int) -> bool { return h >= 0 && h < len(gPcms) && gPcms[h] != nil }

// A playback handle >= 0, or a negative ALSA error code.
pcmOpen :: proc(device: string, rate: int, channels: int) -> int {
	cdev := strings.clone_to_cstring(device, context.temp_allocator)
	pcm: rawptr
	rc := snd_pcm_open(&pcm, cdev, 0, 0)
	if rc < 0 do return int(rc)
	sp := snd_pcm_set_params(pcm, 2, 3, c.uint(channels), c.uint(rate), 1, 100_000)
	if sp < 0 {
		snd_pcm_close(pcm)
		return int(sp)
	}
	append(&gPcms, pcm)
	return len(gPcms) - 1
}

// Frames accepted; negative on an unrecoverable error.
pcmWrite :: proc(h: int, data: [dynamic]u8, frameBytes: int) -> int {
	if !valid(h) || len(data) == 0 || frameBytes <= 0 do return 0
	frames := len(data) / frameBytes
	n := int(snd_pcm_writei(gPcms[h], raw_data(data), c.ulong(frames)))
	if n < 0 {
		n = int(snd_pcm_recover(gPcms[h], c.int(n), 1))
		if n < 0 do return n
		n = int(snd_pcm_writei(gPcms[h], raw_data(data), c.ulong(frames)))
	}
	return n
}

pcmDrain :: proc(h: int) {
	if valid(h) do snd_pcm_drain(gPcms[h])
}

pcmClose :: proc(h: int) {
	if !valid(h) do return
	snd_pcm_close(gPcms[h])
	gPcms[h] = nil
}
