# compiler/module_ids.nim
#
# A module is a ModuleId, not a name. The program's modules are loaded once and
# each is numbered here; everything after the load refers to a module by that
# number: an import names its target by id, a qualified reference names the
# module it reaches by id, and a type copied into an importer is stamped with
# the id of the module that declares it.
#
# Before this, "which module" was a string carried through the compiler, and
# every backend rebuilt the package qualifier from it (`name.replace("-", "_")
# & "."`) and found out which modules to import by searching the emitted text
# for that spelling. A module called `fmt` or `os` was then indistinguishable
# from Odin's own package of that name (#149).
#
# The name is kept for what needs a name: diagnostics and finding the file. The
# spelling a backend emits for a module is `codegen_common.pkgAlias`, the one
# place that decides it.
import tables, hashes, sets, algorithm

type
  ModuleId* = distinct int32

const NoModule* = ModuleId(0)
  ## No module: a declaration that belongs to the module being emitted, or a
  ## reference the checker could not place. Ids start at 1 so the zero value of
  ## a field is this.

proc `==`*(a, b: ModuleId): bool {.borrow.}
proc `<`*(a, b: ModuleId): bool {.borrow.}
proc hash*(a: ModuleId): Hash {.borrow.}
proc `$`*(a: ModuleId): string = "m" & $int32(a)

var
  names: seq[string]                ## index = id - 1
  ids: Table[string, ModuleId]

proc moduleId*(name: string): ModuleId =
  ## The id of the module called `name`, numbering it on first sight. A name is
  ## a module's file base name, which is unique within a program.
  if name.len == 0: return NoModule
  if name in ids: return ids[name]
  names.add name
  result = ModuleId(names.len)
  ids[name] = result

proc isModule*(id: ModuleId): bool = id != NoModule

proc nameOf*(id: ModuleId): string =
  ## The module's name, for a diagnostic or a file lookup. "" for NoModule.
  if id == NoModule: "" else: names[int(id) - 1]

proc knownModule*(name: string): ModuleId =
  ## The id of an already-numbered module, or NoModule. Unlike `moduleId` it
  ## never numbers a new one, so a misspelt name stays unplaced.
  ids.getOrDefault(name, NoModule)

proc cmpByName*(a, b: ModuleId): int =
  ## Order by module name: what a sort of modules uses so an emitted order does
  ## not depend on the order they happened to load in.
  cmp(nameOf(a), nameOf(b))

type ModuleUse* = ref object
  ## The modules the file being emitted reached through. Shared by every
  ## context one file is written with, so a qualifier asked for anywhere in it
  ## lands in the one import list: a file imports exactly the modules it
  ## qualified a name with.
  ids*: HashSet[ModuleId]

proc newModuleUse*(): ModuleUse =
  ModuleUse(ids: initHashSet[ModuleId]())

proc byName*(u: ModuleUse): seq[ModuleId] =
  ## The modules used, in name order, so an import list does not depend on
  ## the order names happened to be asked for.
  for id in u.ids: result.add id
  result.sort(cmpByName)
