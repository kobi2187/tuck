# compiler/kernel_rules.nim — what a kernel module may not contain, judged
# after checking when the build targets a kernel (`--target:linux-kmod |
# windows-kmd`, compiler/kernel_target.nim). Each refusal names the kernel's
# own way to do the thing instead, and fires here rather than as a C
# compiler or loader error long after the source line is out of view.
#
#   TK-KN01  floating point: the kernel does not save FPU state on entry,
#            so the module is compiled without SSE or x87 at all
#   TK-KN02  `buffer` or a `register` at a fixed address: physical addresses
#            mean nothing in a kernel's virtual address space (ioremap /
#            MmMapIoSpace, the DMA API)
#   TK-KN03  `bind`: a kernel driver's interrupt is requested from the
#            kernel (request_irq, IoConnectInterruptEx), not a vector table
#
# The standard library is not judged line by line: Nim emits only what the
# program uses, so an unused float routine in std/ never reaches the C
# compiler; a used one does, and TK-KN01 at the call site would need the
# whole call graph. The program's own modules are.
import std/[strutils, sequtils, os]
import ast, ast_ops, resolution, diagnostics, typecheck_util, semantics

proc kernelFail(code: DiagCode, msg: string, sp: Span) =
  var err = newException(SemanticError, withCode(code, msg))
  err.line = sp.line
  err.col = sp.col
  raise err

proc isFloat(t: Type): bool =
  t != nil and typeName(t).split({'[', ']', ',', ' ', '?', '!', '{', '}', ':'}).anyIt(
    it in ["f32", "f64"])

proc checkFloats(res: Resolution, d: Decl, file: string) =
  for body in d.ownExprs:
    if body == nil: continue
    for n in body.nodes:
      let floaty = (n.kind == exkLit and n.litKind == lkFloat) or
                   isFloat(res.typeFor(n))
      if floaty:
        kernelFail(dcKnFloat, "floating point in a kernel module (" & file &
          "): the kernel does not save FPU state, so the module is built " &
          "without it. Fix: integers, or fixed point (a scaled int)", n.span)
  for t in d.ownTypes:
    if isFloat(t):
      kernelFail(dcKnFloat, "a floating-point type in a kernel module (" & file &
        "): `" & typeName(t) & "`. Fix: integers, or fixed point", d.span)

proc checkKernelRules*(res: Resolution, mods: seq[tuple[path: string, m: Module]],
                       stdDirs: seq[string], target: string) =
  ## Raises the first refusal; returns when the program fits `target`.
  for (path, m) in mods:
    if stdDirs.anyIt(path.startsWith(it)): continue
    let file = path.extractFilename
    for d in m.allDecls:
      if d == nil: continue
      case d.kind
      of dkBuffer:
        kernelFail(dcKnAddress, "`buffer` in a " & target & " module (" & file &
          "): its address is physical, and a kernel runs in virtual memory. " &
          "Fix: allocate DMA memory through the kernel (dma_alloc_coherent, " &
          "AllocateCommonBuffer) behind an extern", d.span)
      of dkRegister:
        if d.regAddress != "":
          kernelFail(dcKnAddress, "`register " & d.name & " at " & d.regAddress &
            "` in a " & target & " module (" & file & "): a physical address. " &
            "Fix: map the device first (ioremap, MmMapIoSpace) and reach it " &
            "behind an extern", d.span)
      of dkBind:
        kernelFail(dcKnBind, "`bind " & d.bindLine & "` in a " & target &
          " module (" & file & "): a kernel driver has no vector table. Fix: " &
          "request the interrupt from the kernel (request_irq, " &
          "IoConnectInterruptEx) behind an extern", d.span)
      else: discard
      checkFloats(res, d, file)
