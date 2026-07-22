# msgpack4nim unpacks Nim case objects by assigning the discriminant after
# construction; this flag relaxes that runtime check (compiler/modules.nim
# AST cache). ponytail: replace with custom unpack procs if the flag ever bites.
switch("define", "nimOldCaseObjects")

# Each backend lowers its OWN copy of the checked AST (tuck.nim), so Nim's
# lowering never mutates the tree Beef then reads. deepCopy needs enabling
# under ORC.
switch("deepcopy", "on")
