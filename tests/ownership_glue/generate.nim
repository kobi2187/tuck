## Compile and run generated glue independently of ownership placement.
import std/[os, tables, strutils]
import ../../compiler/[ast, ownership_glue_odin, codegen_odin_ctx]

proc named(n: string): Type = Type(kind: tkNamed, name: n)
proc app(n: string, args: varargs[Type]): Type =
  Type(kind: tkApp, base: named(n), args: @args)
proc field(n: string, t: Type): FieldDef = FieldDef(name: n, typ: t)
var m: Module
m.decls.add Decl(kind: dkType, name: "Bag",
  typeBody: Type(kind: tkRecord, fields: @[
    field("items", app("Seq", app("Seq", named("int")))),
    field("label", named("str"))]))
m.decls.add Decl(kind: dkType, name: "Tree",
  typeBody: Type(kind: tkSum, variants: @[
    VariantDef(name: "Leaf", fields: @[field("value", named("int"))]),
    VariantDef(name: "Branch", fields: @[field("children", app("Seq", named("Tree")))])]))
m.decls.add Decl(kind: dkType, name: "Nested", generics: @["T"],
  typeBody: Type(kind: tkRecord, fields: @[
    field("inside", Type(kind: tkRecord, fields: @[
      field("items", app("Seq", named("<typeparam:T>")))]))]))
var ctx = newOdinCtx(m, initTable[string, Module](), "", nil)
let bag = ctx.odinGlue(named("Bag"))
let tree = ctx.odinGlue(named("Tree"))
let result = ctx.odinGlue(app("!", named("Bag")))
let arr = ctx.odinGlue(app("Array", named("2"), named("Bag")))
let generic = ctx.odinGlue(app("Nested", named("int")))
let nested = ctx.odinGlue(app("Seq", app("Seq", named("int"))))
let triple = ctx.odinGlue(app("Seq", app("Seq", app("Seq", named("int")))))
let bags = ctx.odinGlue(app("Seq", named("Bag")))
let count = ctx.hoisted.len
doAssert ctx.odinGlue(named("Tree")) == tree
doAssert ctx.hoisted.len == count, "one glue set per instantiated type"
var source = """#+feature dynamic-literals
package main
import rt "RUNTIME"
Bag :: struct { items: [dynamic][dynamic]int, label: string }
Tree_Leaf :: struct { value: int }
Tree_Branch :: struct { children: [dynamic]Tree }
Tree :: union { Tree_Leaf, Tree_Branch }
GLUE
Nested :: struct($T: typeid) { inside: TRec_items([dynamic]T) }
main :: proc() {
 context.allocator = rt.tuckTrackAllocator()
 original := Bag{items = [dynamic][dynamic]int{[dynamic]int{1, 2}},
                 label = rt.tuckStrOwned("owned")}
 duplicate := BAGCOPY(original)
 duplicate.items[0][0] = 9
 assert(original.items[0][0] == 1 && duplicate.label == "owned")
 BAGRESET(&duplicate)
 assert(len(duplicate.items) == 0 && len(duplicate.label) == 0)
 BAGRESET(&duplicate)
 leaves := [dynamic]Tree{Tree_Leaf{1}, Tree_Leaf{2}}
 original_tree: Tree = Tree_Branch{leaves}
 copied_tree := TREECOPY(original_tree)
 TREERESET(&original_tree)
 switch payload in copied_tree {
 case Tree_Branch:
   assert(len(payload.children) == 2)
 case Tree_Leaf: assert(false)
 case: assert(false)
 }
 TREERESET(&copied_tree)
 active := rt.tok(original)
 active_copy := RESULTCOPY(active)
 active_copy.value.items[0][0] = 7
 assert(original.items[0][0] == 1)
 RESULTRESET(&active_copy)
 absent := rt.tnone(Bag)
 absent.value = original // Inactive storage is deliberately poisoned.
 absent_copy := RESULTCOPY(absent)
 assert(absent_copy.status == .Absent && len(absent_copy.value.items) == 0)
 RESULTRESET(&absent_copy)
 RESULTRESET(&absent)
 failed := rt.terr(Bag, 42)
 failed.value = original
 failed_copy := RESULTCOPY(failed)
 assert(failed_copy.status == .Err && failed_copy.err == 42)
 RESULTRESET(&failed_copy)
 fixed := [2]Bag{BAGCOPY(original), BAGCOPY(original)}
 fixed_copy := ARRAYCOPY(fixed)
 fixed_copy[0].items[0][0] = 88
 assert(fixed[0].items[0][0] == 1)
 ARRAYRESET(&fixed)
 ARRAYRESET(&fixed_copy)
 generic := Nested(int){inside = TRec_items([dynamic]int){[dynamic]int{6}}}
 generic_copy := GENERICCOPY(generic)
 generic_copy.inside.items[0] = 99
 assert(generic.inside.items[0] == 6)
 GENERICRESET(&generic)
 GENERICRESET(&generic_copy)
 empty: [dynamic][dynamic]int
 empty_copy := NESTEDCOPY(empty)
 assert(len(empty_copy) == 0)
 NESTEDRESET(&empty_copy)
 NESTEDRESET(&empty)
 with_empty := [dynamic][dynamic]int{[dynamic]int{}, [dynamic]int{7}}
 with_empty_copy := NESTEDCOPY(with_empty)
 assert(len(with_empty_copy[0]) == 0 && with_empty_copy[1][0] == 7)
 NESTEDRESET(&with_empty)
 NESTEDRESET(&with_empty_copy)
 deep := [dynamic][dynamic][dynamic]int{[dynamic][dynamic]int{[dynamic]int{11}}}
 deep_copy := TRIPLECOPY(deep)
 deep_copy[0][0][0] = 12
 assert(deep[0][0][0] == 11)
 TRIPLERESET(&deep)
 assert(deep_copy[0][0][0] == 12)
 TRIPLERESET(&deep_copy)
 bag_list := [dynamic]Bag{BAGCOPY(original)}
 bag_list_copy := BAGSCOPY(bag_list)
 bag_list_copy[0].items[0][0] = 77
 assert(bag_list[0].items[0][0] == 1)
 BAGSRESET(&bag_list)
 BAGSRESET(&bag_list_copy)
 BAGRESET(&original)
 rt.tuckTrackCheck()
}
"""
for pair in [
  ("RUNTIME", relativePath(absolutePath("compiler/tuckrt"), absolutePath(paramStr(1)))),
  ("GLUE", ctx.hoisted.join("\n")),
  ("BAGCOPY", bag.copy), ("BAGRESET", bag.reset),
  ("TREECOPY", tree.copy), ("TREERESET", tree.reset),
  ("RESULTCOPY", result.copy), ("RESULTRESET", result.reset),
  ("ARRAYCOPY", arr.copy), ("ARRAYRESET", arr.reset),
  ("GENERICCOPY", generic.copy), ("GENERICRESET", generic.reset),
  ("NESTEDCOPY", nested.copy), ("NESTEDRESET", nested.reset),
  ("TRIPLECOPY", triple.copy), ("TRIPLERESET", triple.reset),
  ("BAGSCOPY", bags.copy), ("BAGSRESET", bags.reset)]:
  source = source.replace(pair[0], pair[1])
createDir(paramStr(1))
writeFile(paramStr(1) / "main.odin", source)
