# msgpack4nim unpacks Nim case objects by assigning the discriminant after
# construction; this flag relaxes that runtime check (compiler/modules.nim
# AST cache). ponytail: replace with custom unpack procs if the flag ever bites.
switch("define", "nimOldCaseObjects")

# Each backend lowers its OWN copy of the checked AST (tuck.nim), so Nim's
# lowering never mutates the tree Odin then reads. deepCopy needs enabling
# under ORC.
switch("deepcopy", "on")

# --- Build speed. This is a COMPILER project: the compiler is rebuilt on
# every test run, so build time is inner-loop time, not release time. None of
# these change emitted output.
when not defined(release) and not defined(danger):
  switch("cc", "clang")            # ~15% faster than gcc here
  switch("incremental", "on")      # reuse per-module C for untouched modules
  switch("parallelBuild", "0")     # 0 = one C job per core

