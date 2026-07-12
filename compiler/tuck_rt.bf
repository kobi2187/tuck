// compiler/tuck_rt.bf
// Shared Tuck runtime for the Beef backend — the Beef counterpart of
// tuck_rt.nim. Generated programs reference it via `using TuckRt;` and
// `using static TuckRt.Rt;` so tok/terr/... resolve unqualified, matching
// the Nim backend's `import tuck_rt`.
namespace TuckRt;

using System;
using System.IO;

// --- Errors and absence: !T / ?T lower to one value type (no alloc, no nil) ---
// ?T is an option: absence is a first-class state, not a reserved error code.
// !T uses tsOk/tsErr, ?T uses tsOk/tsAbsent, !?T may be any of the three.
public enum TuckStatus
{
	tsOk,
	tsErr,
	tsAbsent
}

// The Beef stand-in for Nim's empty tuple payload of `!void`.
public struct TuckUnit
{
}

public struct TuckResult<T>
{
	public TuckStatus status;
	public uint16 err;    // app-wide error code; meaningful only when status == tsErr
	public T value;

	public bool ok => status == .tsOk;
}

// Record payload shapes returned by the runtime's stdlib layer. Generated
// call sites use inferred locals, so these stay private to the runtime.
public struct FsContent
{
	public String content;
	public this(String content) { this.content = content; }
}

public struct IoLine
{
	public String line;
	public this(String line) { this.line = line; }
}

public struct EnvValue
{
	public String value;
	public this(String value) { this.value = value; }
}

public static class Rt
{
	public static TuckResult<T> tok<T>(T v)
	{
		TuckResult<T> r = default;
		r.status = .tsOk;
		r.value = v;
		return r;
	}

	public static TuckResult<TuckUnit> tokVoid()
	{
		TuckResult<TuckUnit> r = default;
		r.status = .tsOk;
		return r;
	}

	public static TuckResult<T> terr<T>(uint16 code)
	{
		TuckResult<T> r = default;
		r.status = .tsErr;
		r.err = code;
		return r;
	}

	public static TuckResult<T> tnone<T>()
	{
		TuckResult<T> r = default;
		r.status = .tsAbsent;
		return r;
	}

	// `?` propagation: forward failure OR absence unchanged (status-preserving)
	public static TuckResult<T> tfwd<T>(TuckStatus status, uint16 err)
	{
		TuckResult<T> r = default;
		r.status = status;
		r.err = err;
		return r;
	}

	public static void tuckReportUnhandled(uint16 code, StringView site)
	{
		Console.WriteLine("TUCK UNHANDLED: error {} at {}", code, site);
	}

	// ---------- stdlib externs (std/*.tuck) ----------
	// Error codes are FNV-1a hashes precomputed by the emitter; these values
	// mirror errCode("...") in tuck_rt.nim.
	const uint16 cFsNotFound = 0x45A7;     // FsError.NotFound
	const uint16 cFsIoFailed = 0x9E2E;     // FsError.IoFailed
	const uint16 cFsAccessDenied = 0x65BD; // FsError.AccessDenied
	const uint16 cIoEndOfInput = 0x271D;   // IoError.EndOfInput
	const uint16 cIoIoFailed = 0xC02F;     // IoError.IoFailed

	public static TuckResult<FsContent> readFile(StringView path)
	{
		let text = new String();
		if (File.ReadAllText(path, text) case .Err)
		{
			delete text;
			return terr<FsContent>(cFsNotFound);
		}
		return tok(FsContent(text));
	}

	public static TuckResult<TuckUnit> writeFile(StringView path, StringView content)
	{
		if (File.WriteAllText(path, content) case .Err)
			return terr<TuckUnit>(cFsAccessDenied);
		return tokVoid();
	}

	public static TuckResult<TuckUnit> appendFile(StringView path, StringView content)
	{
		if (File.WriteAllText(path, content, true) case .Err)
			return terr<TuckUnit>(cFsAccessDenied);
		return tokVoid();
	}

	public static TuckResult<TuckUnit> removeFile(StringView path)
	{
		if (!File.Exists(path))
			return terr<TuckUnit>(cFsNotFound);
		if (File.Delete(path) case .Err)
			return terr<TuckUnit>(cFsAccessDenied);
		return tokVoid();
	}

	public static bool fileExists(StringView path)
	{
		return File.Exists(path);
	}

	public static void print(StringView text)
	{
		Console.Write(text);
	}

	public static void printLine(StringView text)
	{
		Console.WriteLine(text);
	}

	public static TuckResult<IoLine> readLine()
	{
		let text = new String();
		if (Console.ReadLine(text) case .Err)
		{
			delete text;
			return terr<IoLine>(cIoEndOfInput);
		}
		return tok(IoLine(text));
	}

	[CLink]
	static extern char8* getenv(char8* name);

	public static TuckResult<EnvValue> getEnv(StringView name)
	{
		let cstr = getenv(scope String(name).CStr());
		if (cstr == null)
			return tnone<EnvValue>();
		return tok(EnvValue(new String(cstr)));
	}

	public static void exit(int code)
	{
		Environment.Exit((int32)code);
	}

	public static uint64 nowMs()
	{
		return (uint64)(DateTime.UtcNow.Ticks / TimeSpan.TicksPerMillisecond);
	}

	public static void sleepMs(uint32 ms)
	{
		System.Threading.Thread.Sleep((int32)ms);
	}
}

// --- Actor mailbox: fixed-capacity ring buffer, mirrors Mailbox[T, Cap] ---
public struct Mailbox<T, C> where C : const int
{
	public T[C] data;
	public int head;
	public int tail;

	public bool enqueue(T msg) mut
	{
		let next = (tail + 1) % C;
		if (next == head)
			return false;
		data[tail] = msg;
		tail = next;
		return true;
	}

	public bool dequeue(ref T msg) mut
	{
		if (head == tail)
			return false;
		msg = data[head];
		head = (head + 1) % C;
		return true;
	}
}

// --- Fixed-buffer allocators: mirrors BumpArena / ObjectPool ---
public struct BumpArena<Size> where Size : const int
{
	public uint8[Size] buffer;
	public int cursor;

	public void* alloc(int bytes) mut
	{
		if (cursor + bytes > Size)
			Runtime.FatalError("Arena buffer exhausted");
		void* p = &buffer[cursor];
		cursor += bytes;
		return p;
	}

	public void reset() mut
	{
		cursor = 0;
	}
}

public struct ObjectPool<T, C> where T : struct where C : const int
{
	public T[C] storage;
	public uint64 occupied;

	public T* acquire() mut
	{
		for (int i = 0; i < C; i++)
		{
			if ((occupied & (1UL << i)) == 0)
			{
				occupied |= (1UL << i);
				return &storage[i];
			}
		}
		return null;
	}

	public void release(T* item) mut
	{
		let baseAddr = (int)(void*)&storage[0];
		let itemAddr = (int)(void*)item;
		let index = (itemAddr - baseAddr) / sizeof(T);
		if (index >= 0 && index < C)
			occupied &= ~(1UL << index);
	}
}

// --- MMIO register declarations: attribute markers the codegen references.
// The Nim backend synthesizes bit accessors with a macro; on Beef the
// attributes carry the layout so a later comptime pass (or hand-written
// driver) can use them. They must exist for generated code to compile.
public enum AccessMode
{
	ReadOnly,
	WriteOnly,
	ReadWrite
}

[AttributeUsage(.Class | .Struct)]
public struct RegisterMMIOAttribute : Attribute
{
	public this(int address)
	{
	}
}

[AttributeUsage(.Field)]
public struct BitAttribute : Attribute
{
	public this(int index, AccessMode mode)
	{
	}
}
