# compiler/typecheck_registry.nim
#
# Whole-program registry validation (spec Part 10): every registry event has
# exactly one raiser and one handler. Runs once, AFTER every module's own
# typecheck, over raw pre-lowering AST shapes — never during expression
# synthesis, so it has no dependency on synthesizeKind's recursive dispatch.
import ast, tables, sets, sequtils, strutils
import ast_query
import typecheck_util

type RegistryEvents* = tuple[regs: Table[string, Decl],
                            variants: Table[string, VariantDef]]

proc fnv16*(name: string): uint16 =
  var h = 2166136261'u32
  for c in name:
    h = (h xor uint32(c)) * 16777619'u32
  uint16((h xor (h shr 16)) and 0xFFFF'u32)

proc raisedEventsIn*(e: Expr, into: var seq[tuple[reg, ev: string, sp: Span,
                                                  payload: Expr]]) =
  ## Every `Registry.raise Event {payload}` reachable from `e`.
  ##
  ## Matched on the PRE-LOWERING shape — a call whose callee is a call whose
  ## single argument is a `.raise` field access — because lowering.nim
  ## flattens exactly this into `raise_Registry_Event` and the checker runs
  ## first. Keeping the two in step matters: if the parse shape changes, this
  ## silently stops finding raises, so the suite asserts a bad raise is
  ## rejected rather than asserting this walker's internals.
  ## Walks EVERY child via ast.children. It used to list ten kinds and
  ## `else: discard`, which silently skipped the rest — a raise inside a
  ## `send` payload, a select arm or either side of a binary was not found,
  ## and an unfound raise is an UNCHECKED one.
  ##
  ## KNOWN GAP, not this proc's: checkRaiseSites feeds it from `allFns`, which
  ## yields dkFn only — so a raise in a TASK body is never scanned no matter
  ## how thorough the walk is. Verified 2026-08-14: a typo'd event inside an
  ## `on select` arm of a task passes `tuck ch` clean. Fixing it means
  ## widening allFns (ast_query.nim:152), whose own comment already warns that
  ## per-site kind lists are how dkActor came to be silently skipped.
  if e == nil: return
  if e.kind == exkCall and e.callee != nil and e.callee.kind == exkCall and
     e.callee.callee != nil and e.callee.callee.kind == exkVar and
     e.callee.args.len == 1 and e.callee.args[0].kind == exkField:
    let f = e.callee.args[0]
    if f.fieldName == "raise" and f.receiver != nil and
       f.receiver.kind == exkRegistryRef:
      into.add((f.receiver.refName, e.callee.callee.name, e.span,
                if e.args.len == 1: e.args[0] else: nil))
  for c in e.children: raisedEventsIn(c, into)

proc checkRaisePayload*(key: string, want: seq[FieldDef], payload: Expr,
                       sp: Span) =
  ## The payload a raise supplies must be exactly the variant's fields — the
  ## declaration is the contract, both ways.
  if payload == nil or payload.kind != exkStruct:
    if want.len > 0:
      fail(dcRgPayload,
           "event '" & key & "' carries a payload (" &
           want.mapIt(it.name).join(", ") & "), but none was given", sp)
    return
  var given: HashSet[string]
  for f in payload.fields: given.incl(f.name)
  for w in want:
    if w.name notin given:
      fail(dcRgPayload,
           "event '" & key & "' is missing payload field '" & w.name &
           "' — the registry variant's declaration is the contract", sp)
  for f in payload.fields:
    if not want.anyIt(it.name == f.name):
      fail(dcRgPayload,
           "event '" & key & "' has no payload field '" & f.name &
           "' — the registry declares " &
           (if want.len == 0: "no payload"
            else: want.mapIt(it.name).join(", ")), sp)

proc collectRegistries*(mods: seq[tuple[name, path: string, m: Module]]):
                       RegistryEvents =
  ## RULE 1 — a program declares ONE registry, so the whole event surface
  ## reads in one place.
  var firstReg = ""
  for (_, _, m) in mods:
    for d in m.decls:
      if d == nil or d.kind != dkRegistry: continue
      if firstReg != "" and d.name != firstReg:
        fail(dcRgDuplicate,
             "registry '" & d.name & "': a program declares ONE registry " &
             "(spec Part 10) and '" & firstReg & "' is already declared — " &
             "the point is that the whole event surface reads in one place",
             d.span)
      firstReg = d.name
      result.regs[d.name] = d
      for v in d.variants: result.variants[d.name & "." & v.name] = v

proc collectHandlers*(mods: seq[tuple[name, path: string, m: Module]],
                     ev: RegistryEvents): HashSet[string] =
  ## RULE 2 — an `on Registry.Event` handler may only name a declared event.
  ## Handlers are parsed as fns named `Registry.Event`.
  for (_, _, m) in mods:
    for d in m.decls:
      if d == nil or d.kind != dkFn or "." notin d.name: continue
      let parts = d.name.split('.')
      if parts.len != 2 or parts[0] notin ev.regs: continue
      if d.name notin ev.variants:
        fail(dcRgUnknownEvent,
             "no event '" & parts[1] & "' in registry '" & parts[0] &
             "' — `on` may only handle variants the registry declares",
             d.span)
      result.incl(d.name)

proc failIfUnhandledEvent*(ev: RegistryEvents, handled: HashSet[string]) =
  ## RULE 3 — an event nobody handles is a signal that goes nowhere.
  for key, v in ev.variants:
    if key notin handled:
      fail(dcRgNoHandler,
           "event '" & key & "' has no handler — every declared event needs " &
           "at least one `on " & key & "(...)`, or remove the variant",
           v.span)

proc checkErrCodeCollisions*(mods: seq[tuple[name, path: string, m: Module]]) =
  ## Every declared error id ("module/Enum.Variant") must hash uniquely
  ## across the whole program. The forward table is built here; a collision
  ## is a compile error with a rename pointer.
  var seen = initTable[uint16, string]()
  for (name, path, m) in mods:
    for d in m.sumTypes():
      if d.span.file.startsWith(ImportedTypeMarker): continue  # origin owns it
      for v in d.typeBody.variants:
        if v.fields.len > 0: continue  # error enums are fieldless
        let full = name & "/" & d.name & "." & v.name
        let code = fnv16(full)
        if seen.hasKey(code) and seen[code] != full:
          fail("Error Id Collision: '" & full & "' and '" & seen[code] &
               "' hash to the same 16-bit code (0x" & $code &
               ") — rename one variant", d.span)
        seen[code] = full

proc checkRaiseSites*(mods: seq[tuple[name, path: string, m: Module]],
                     ev: RegistryEvents) =
  ## RULE 4 — a raise must name a declared event, carry the right payload, and
  ## not come from the handler of that same event (raising is synchronous, so
  ## that is an immediate infinite loop).
  for (_, _, m) in mods:
    for d in m.allFns():
      var raises: seq[tuple[reg, ev: string, sp: Span, payload: Expr]]
      raisedEventsIn(d.fnBody, raises)
      for r in raises:
        if r.reg notin ev.regs: continue        # not a registry raise at all
        let key = r.reg & "." & r.ev
        if key notin ev.variants:
          fail(dcRgUnknownEvent,
               "registry '" & r.reg & "' declares no event '" & r.ev &
               "' — `raise` may only name variants the registry declares",
               r.sp)
        if d.name == key:
          fail(dcRgSelfRaise,
               "handler for '" & key & "' raises the event it handles — " &
               "raising is synchronous, so this is an immediate infinite " &
               "loop", r.sp)
        checkRaisePayload(key, ev.variants[key].fields, r.payload, r.sp)

proc checkRegistry*(mods: seq[tuple[name, path: string, m: Module]]) =
  ## spec Part 10: the whole event surface is readable from the `registry`
  ## declaration plus its `on Registry.Event` handlers. That promise needs
  ## four rules, none of which were enforced — a raise naming a typo'd event
  ## reached the backend and became a Nim "invalid indentation" error, and an
  ## event nobody handled compiled to a signal that silently went nowhere.
  let ev = collectRegistries(mods)
  if ev.regs.len == 0: return
  let handled = collectHandlers(mods, ev)
  failIfUnhandledEvent(ev, handled)
  checkRaiseSites(mods, ev)
