# compiler/event_audit.nim
#
# `tuck audit FILE --events`: the program's whole event surface as a report.
#
# Spec Part 10 promised that the entire event surface reads in one place. The
# owner's ruling of 2026-11-22 (interrupts are events) gave each module its
# own registry, so a driver can declare the events it raises; the "one place"
# became this report instead of one declaration. For every registry: where it
# is declared, each event, every site that raises it and every handler.
import std/[os, strutils, tables]
import ast, ast_ops, ast_query
import typecheck_registry, typecheck_util

type
  EventSite* = object
    file*: string
    line*: int
    what*: string        ## the enclosing fn or task, or "actor X" for a handler

  EventRow* = object
    registry*, event*: string
    payload*: string     ## `{n: int}`, or "" for none
    raisers*, handlers*: seq[EventSite]

  RegistryRow* = object
    name*, module*: string
    site*: EventSite
    events*: seq[EventRow]

proc siteOf(path: string, sp: Span, what: string): EventSite =
  ## Spans carry a line, not a file, so the module's path names the file.
  EventSite(file: extractFilename(path), line: sp.line, what: what)

proc payloadText(v: VariantDef): string =
  ## The payload, then the delivery as the driver wrote it:
  ## `{data: u8}  [stream, overflow: drop_newest]`.
  if v.fields.len > 0:
    var parts: seq[string]
    for f in v.fields: parts.add f.name & ": " & typeName(f.typ)
    result = "{" & parts.join(", ") & "}"
  const words: array[EventDelivery, string] = ["", "stream", "signal", "latest"]
  if v.delivery != edNone:
    result.add "  [" & words[v.delivery] &
               (if v.overflow == "": "" else: ", overflow: " & v.overflow) & "]"

proc handlerWhat(d: Decl): string =
  ## An actor's handler reaches the report as the forwarder rewrite lifted
  ## beside it: a body that is one send to the actor.
  let b = d.fnBody
  if b != nil and b.kind == exkBlock and b.stmts.len == 1 and
     b.stmts[0] != nil and b.stmts[0].kind == exkSend:
    return "actor " & b.stmts[0].sendActor
  "top level"

type EventIndex = Table[string, (int, int)]   ## "Reg.Ev" -> (row, event)

proc registryRows(mods: seq[tuple[name, path: string, m: Module]],
                  index: var EventIndex): seq[RegistryRow] =
  ## Every registry, in module order (dependencies first), its events in
  ## declaration order.
  for (modName, path, m) in mods:
    for d in m.decls:
      if d == nil or d.kind != dkRegistry or isImportedCopy(d): continue
      var row = RegistryRow(name: writtenName(d), module: modName,
                            site: siteOf(path, d.span, ""))
      for v in d.variants:
        index[row.name & "." & v.name] = (result.len, row.events.len)
        row.events.add EventRow(registry: row.name, event: v.name,
                                payload: payloadText(v))
      result.add row

proc addSites(rows: var seq[RegistryRow], index: EventIndex, path: string,
              d: Decl) =
  ## `d`'s part of the surface: it may be a handler, and it may raise.
  if d.kind == dkFn and d.isOnHandler and writtenName(d) in index:
    let (r, e) = index[writtenName(d)]
    rows[r].events[e].handlers.add siteOf(path, d.span, handlerWhat(d))
  var raises: seq[tuple[reg, ev: string, sp: Span, payload: Expr]]
  for e in d.ownExprs: raisedEventsIn(e, raises)
  for x in raises:
    let key = x.reg & "." & x.ev
    if key notin index: continue
    let (r, e) = index[key]
    rows[r].events[e].raisers.add siteOf(path, x.sp, writtenName(d))

proc eventSurface*(mods: seq[tuple[name, path: string, m: Module]]):
                  seq[RegistryRow] =
  ## Every registry, its events, and their raisers and handlers.
  var index: EventIndex
  result = registryRows(mods, index)
  for (_, path, m) in mods:
    for d in m.allDecls:
      if d != nil and not isImportedCopy(d): result.addSites(index, path, d)

proc sitesText(sites: seq[EventSite]): string =
  if sites.len == 0: return "none"
  var parts: seq[string]
  for s in sites:
    parts.add s.file & ":" & $s.line & (if s.what == "": "" else: " (" & s.what & ")")
  parts.join(", ")

proc renderEvents*(rows: seq[RegistryRow]): string =
  ## The human report: one block per registry.
  var nEvents = 0
  for r in rows: nEvents += r.events.len
  result = "EVENTS (" & $rows.len & " registr" &
           (if rows.len == 1: "y" else: "ies") & ", " & $nEvents & " event" &
           (if nEvents == 1: "" else: "s") & ")\n"
  if rows.len == 0:
    result.add "  no registry is declared\n"
    return
  for r in rows:
    result.add "\n  " & r.name & "  (module " & r.module & ", " & r.site.file &
               ":" & $r.site.line & ")\n"
    for ev in r.events:
      result.add "    " & ev.event & ev.payload & "\n"
      result.add "      raised by:  " & sitesText(ev.raisers) & "\n"
      result.add "      handled by: " & sitesText(ev.handlers) & "\n"
