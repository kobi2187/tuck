// D host shim for the embedded experiment — twin of hal_shim.nim.
// Same contract as the Nim and Odin versions: no real MMIO, the observable
// lines are the assertion surface for a three-target host run.
module hal_shim;

import std.stdio : write, writeln;

void ledOn()
{
    writeln("LED ON");
}

void ledOff()
{
    writeln("LED OFF");
}

void delayMs(long ms)
{
    // No wall-clock wait: virtual time is the QEMU loop's job.
}

void regWrite(uint a, uint value)
{
    writeln("REG WRITE ", a, " = ", value);
}

uint regRead(uint a)
{
    return 0;
}

bool buttonPressed()
{
    return false;
}

bool uartHasByte()
{
    return false;
}

ubyte uartReadByte()
{
    return 0;
}

void uartWriteByte(ubyte b)
{
    writeln("UART TX ", b);
}

void ledSet(ubyte id, bool lit)
{
    writeln("LED ", id, lit ? " ON" : " OFF");
}

void applyState(bool l0, bool l1)
{
    writeln("STATE l0=", l0, " l1=", l1);
}
