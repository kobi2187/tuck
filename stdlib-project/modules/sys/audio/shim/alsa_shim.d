// D impl module for sys.audio's ALSA playback — the twin of alsa_shim.nim.
module alsa_shim;

import std.string : toStringz;

pragma(lib, "asound");

private extern (C) nothrow @nogc
{
    int snd_pcm_open(void** pcm, const(char)* name, int stream, int mode);
    int snd_pcm_set_params(void* pcm, int format, int access_, uint channels, uint rate,
                           int soft, uint latency);
    long snd_pcm_writei(void* pcm, const(void)* buf, ulong frames);
    int snd_pcm_recover(void* pcm, int err, int silent);
    int snd_pcm_drain(void* pcm);
    int snd_pcm_close(void* pcm);
}

private __gshared void*[] gPcms;

private bool valid(long h) { return h >= 0 && h < gPcms.length && gPcms[cast(size_t) h] !is null; }

/// A playback handle >= 0, or a negative ALSA error code.
long pcmOpen(string device, long rate, long channels)
{
    void* pcm;
    auto rc = snd_pcm_open(&pcm, toStringz(device), 0, 0);
    if (rc < 0) return rc;
    auto sp = snd_pcm_set_params(pcm, 2, 3, cast(uint) channels, cast(uint) rate, 1, 100_000);
    if (sp < 0)
    {
        snd_pcm_close(pcm);
        return sp;
    }
    gPcms ~= pcm;
    return cast(long) gPcms.length - 1;
}

/// Frames accepted; negative on an unrecoverable error.
long pcmWrite(long h, ubyte[] data, long frameBytes)
{
    if (!valid(h) || data.length == 0 || frameBytes <= 0) return 0;
    auto frames = data.length / cast(size_t) frameBytes;
    long n = snd_pcm_writei(gPcms[cast(size_t) h], data.ptr, frames);
    if (n < 0)
    {
        n = snd_pcm_recover(gPcms[cast(size_t) h], cast(int) n, 1);
        if (n < 0) return n;
        n = snd_pcm_writei(gPcms[cast(size_t) h], data.ptr, frames);
    }
    return n;
}

void pcmDrain(long h)
{
    if (valid(h)) snd_pcm_drain(gPcms[cast(size_t) h]);
}

void pcmClose(long h)
{
    if (!valid(h)) return;
    snd_pcm_close(gPcms[cast(size_t) h]);
    gPcms[cast(size_t) h] = null;
}
