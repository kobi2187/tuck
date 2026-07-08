# msgpack4nim unpacks Nim case objects by assigning the discriminant after
# construction; this flag relaxes that runtime check (compiler/modules.nim
# AST cache). ponytail: replace with custom unpack procs if the flag ever bites.
switch("define", "nimOldCaseObjects")
