# compiler/typecheck_registry.nim
#
# Whole-program registry validation (spec Part 10): every registry event has
# exactly one raiser and one handler. Runs once, AFTER every module's own
# typecheck, over raw pre-lowering AST shapes — never during expression
# synthesis, so it has no dependency on synthesizeKind's recursive dispatch.
import ast, tables, sets, sequtils, strutils
import ast_query, ast_ops
import typecheck_util

type RegistryEvents* = tuple[regs: Table[string, Decl],
                            variants: Table[string, VariantDef]]
  ## Every registry in the program by name, and every event (variant) by
  ## `Registry.Event` name — what the raiser/handler pairing checks against.

proc isRaiseOf(e: Expr): string =
  ## The registry `e` raises on, when `e` is `Event(Registry.raise)` (how
  ## `Registry.raise Event` parses), else "".
  if e == nil or e.kind != exkCall or e.callee == nil or
     e.callee.kind != exkVar or e.args.len != 1 or e.args[0] == nil or
     e.args[0].kind != exkField:
    return ""
  let f = e.args[0]
  if f.fieldName == "raise" and f.receiver != nil and
     f.receiver.kind == exkRegistryRef:
    return f.receiver.refName
  ""

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
  ## checkRaiseSites feeds it every expression every declaration owns
  ## (allDecls + ownExprs), so a raise in a task body or a select arm is
  ## checked too; until 2026-11-22 it fed it `allFns`, and a typo'd event in
  ## a task's `on select` arm passed `tuck ch` clean.
  if e == nil: return
  if e.kind == exkCall and e.callee != nil and e.callee.kind == exkCall and
     isRaiseOf(e.callee) != "":
    # `Registry.raise Event {payload}`: the inner call is the raise without
    # its payload, so it is recorded here and not walked again below.
    into.add((isRaiseOf(e.callee), e.callee.callee.name, e.span,
              if e.args.len == 1: e.args[0] else: nil))
    for a in e.args: raisedEventsIn(a, into)
    return
  if isRaiseOf(e) != "":
    # `Registry.raise Event`, no payload. Until 2026-11-22 only the payload
    # shape was matched, so a payload-less raise was in no report and a
    # typo in one was an unknown-callable error rather than TK-RG01.
    into.add((isRaiseOf(e), e.callee.name, e.span, nil))
    return
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

proc checkDelivery(key: string, v: VariantDef) =
  ## A delivery kind's words must fit together (owner ruling 2026-11-22):
  ## a signal is a count, so it has no payload; only a stream queues, so
  ## only a stream overflows, and its policy is one of two.
  if v.delivery == edSignal and v.fields.len > 0:
    fail(dcRgSignalPayload,
         "event '" & key & "' is a `[signal]` but carries a payload: repeats " &
         "merge into a count, so there is no one payload to deliver", v.span)
  if v.overflow != "" and v.delivery != edStream:
    fail(dcRgOverflow,
         "event '" & key & "' names `overflow: " & v.overflow & "` but is " &
         "not a `[stream]` — only a stream queues, so only a stream overflows",
         v.span)
  if v.overflow notin ["", "drop_newest", "drop_oldest"]:
    fail(dcRgOverflow,
         "event '" & key & "': no overflow policy '" & v.overflow &
         "' — write `drop_newest` or `drop_oldest`; an interrupt never waits",
         v.span)

proc collectRegistries*(mods: seq[tuple[name, path: string, m: Module]]):
                       RegistryEvents =
  ## RULE 1 (ruled 2026-11-22) — a registry per MODULE, so a driver declares
  ## the events it raises, and registry names are unique program-wide, so
  ## `on Registry.Event` reaches exactly one. The whole surface is a report
  ## (`tuck audit --events`) rather than one declaration.
  # Name uniqueness (TK-RG07) is resolve_refs' collect, which runs first.
  for (modName, _, m) in mods:
    var mine = ""
    for d in m.decls:
      if d == nil or d.kind != dkRegistry or isImportedCopy(d): continue
      if mine != "" and d.name != mine:
        fail(dcRgPerModule,
             "registry '" & d.name & "': module '" & modName & "' already " &
             "declares registry '" & mine & "' — a module declares at most one",
             d.span)
      mine = d.name
      result.regs[d.name] = d
      for v in d.variants:
        checkDelivery(d.name & "." & v.name, v)
        result.variants[d.name & "." & v.name] = v

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
      if d.origin != NoModule: continue  # origin owns it
      for v in d.typeBody.variants:
        if v.fields.len > 0: continue  # error enums are fieldless
        let full = name & "/" & d.name & "." & v.name
        let code = errIdCode(full)
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
    # allDecls + ownExprs, not allFns: a raise in a TASK body, or a select
    # arm, was never checked (the KNOWN GAP raisedEventsIn's comment names).
    for d in m.allDecls:
      if d == nil or isImportedCopy(d): continue
      var raises: seq[tuple[reg, ev: string, sp: Span, payload: Expr]]
      for e in d.ownExprs: raisedEventsIn(e, raises)
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
