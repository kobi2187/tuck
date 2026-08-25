# sys.dynload — Tuck translation

## Blocked, on a rule rather than a gap.

`dlopen`/`dlsym` hands back **a function pointer**, and that is exactly
what the containment rule refuses to let land in a Tuck value:

> A pointer may be produced by an extern and consumed by another extern,
> but it may never be **stored** … illegal in a record field, a plain fn
> signature, a `Seq` element, a mixin member, or an actor field.

The library handle itself is fine — a fieldless extern type is an opaque
handle, explicitly exempt, and may be returned (`FRICTIONS.md` #7, the
`sqlite3*` precedent). So `dlopen` is expressible:

```tuck
extern [c, header: "dlfcn.h"]:
  type LibHandle = {}
  fn dlopen({path: cstring, flags: i32}) -> LibHandle [emit: "dlopen"]
  fn dlclose({h: LibHandle}) -> i32 [emit: "dlclose"]
```

**`dlsym` is the problem.** Its result must become something callable in
Tuck, which means either storing a function pointer (forbidden) or
converting it to a `fnsig` value — and `fnsig` slots are filled by `:name`
references to *statically known* functions, resolved and mangled at compile
time. There is no path from a runtime address to a `fnsig`.

## What this rules out, concretely
Plugin architectures: load a `.so` at runtime, call functions in it that
the compiler never saw. That is the module's entire purpose, and it is
unavailable.

## What still works
Everything `sys.ffi` covers — linking against a library **known at compile
time**, including one resolved by the dynamic linker at process start. The
distinction is *compile-time-known symbol* versus *runtime-discovered
symbol*; only the second is blocked.

## The open question
Whether Tuck wants runtime symbol loading at all is a real design decision,
not an oversight. It conflicts with several things the language leans on —
whole-program mangling before either backend, `fnsig` slots emitting as
generic params for direct calls, and the "no stored pointers" safety
argument. A plugin story would need its own mechanism (a registration
table of statically-known handlers, say) rather than `dlsym`.

## Recommendation
Drop as a module; record the plugin question as a language-level one.
