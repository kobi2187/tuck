## The stdlib's layering (`stdlib-project/LAYERS.txt`): every module sits in a
## layer, and imports only modules of a strictly lower one. Pure file reading,
## so it runs in every mode. A new module that is not listed, or an import that
## points sideways or upward, fails here with the module and the import named.

import std/[os, strutils, tables]
import ../harness

proc importsOf(path: string): seq[string] =
  for line in lines(path):
    if line.startsWith("import "):
      let words = line.splitWhitespace()
      if words.len >= 2: result.add words[1]

proc run*(t: var T) =
  var layer = initTable[string, int]()
  for line in lines(t.root / "stdlib-project" / "LAYERS.txt"):
    if line.len == 0 or line[0] == '#': continue
    let words = line.splitWhitespace()
    for w in words[1 .. ^1]: layer[w] = parseInt(words[0])
  var unlisted, upward: seq[string]
  let modules = t.root / "stdlib-project" / "modules"
  for path in walkDirRec(modules):
    if not path.endsWith(".tuck") or "/shim/" in path or "/mod_" in path: continue
    let name = splitFile(path).name
    if name notin layer:
      unlisted.add name
      continue
    for imp in importsOf(path):
      if imp in layer and layer[imp] >= layer[name]:
        upward.add name & " (layer " & $layer[name] & ") imports " & imp &
                   " (layer " & $layer[imp] & ")"
  if unlisted.len == 0: t.ok "every stdlib module is listed in LAYERS.txt"
  else: t.no "every stdlib module is listed in LAYERS.txt",
             "not listed: " & unlisted.join(", ")
  if upward.len == 0: t.ok "every import points to a strictly lower layer"
  else: t.no "every import points to a strictly lower layer", upward.join("; ")
  t.finish()
