## Rule G is a type graph, not a depth-limited list of direct Seq fields.
import ../../compiler/[ast, ownership_glue]

proc named(n: string): Type = Type(kind: tkNamed, name: n)
proc app(n: string, args: varargs[Type]): Type =
  Type(kind: tkApp, base: named(n), args: @args)
proc field(n: string, t: Type): FieldDef = FieldDef(name: n, typ: t)
proc record(fs: varargs[FieldDef]): Type = Type(kind: tkRecord, fields: @fs)

var m: Module
let ints = app("Seq", named("int"))
let nested = app("Seq", ints)
let nestedPlan = glueFor(m, nested)
doAssert nestedPlan.kind == gSequence and nestedPlan.owns
doAssert nestedPlan.children[0].node.kind == gSequence
doAssert not nestedPlan.children[0].node.children[0].node.owns

let boxed = app("?", record(field("items", ints), field("label", named("str"))))
let boxedPlan = glueFor(m, boxed)
doAssert boxedPlan.kind == gResult and boxedPlan.owns
doAssert boxedPlan.children[0].node.kind == gRecord
doAssert boxedPlan.children[0].node.children.len == 2
doAssert glueFor(m, app(UninitName, ints)).kind == gSequence

let arrayPlan = glueFor(m, app("Array", named("4"), ints))
doAssert arrayPlan.kind == gArray and arrayPlan.owns
doAssert arrayPlan.children[0].node.kind == gSequence

# Deep records must not stop owning memory at an arbitrary recursion depth.
var deep = ints
for i in 0 .. 15:
  deep = record(field("nested", deep))
doAssert glueFor(m, deep).owns

m.decls.add Decl(kind: dkType, name: "Box", generics: @["T"],
                 typeBody: record(field("value", named("T"))))
doAssert glueFor(m, app("Box", named("int"))).kind == gRecord
doAssert not glueFor(m, app("Box", named("int"))).owns
doAssert glueFor(m, app("Box", ints)).owns

# A generic's argument must be instantiated in its caller's environment,
# before the callee shadows a parameter with the same spelling.
m.decls.add Decl(kind: dkType, name: "Outer", generics: @["T"],
                 typeBody: app("Box", named("T")))
doAssert glueFor(m, app("Outer", ints)).owns
m.decls.add Decl(kind: dkType, name: "Phantom", generics: @["T"],
                 typeBody: named("int"))
doAssert not glueFor(m, app("Phantom", ints)).owns
m.decls.add Decl(kind: dkType, name: "Nested", generics: @["T"],
  typeBody: record(field("inside", record(field("items", app("Seq", named("T")))))))
let genericShape = glueFor(m, app("Nested", named("int")))
doAssert genericShape.children[0].node.typ.fields[0].typ.args[0].name == "int"

# An alias can be visited while its target is still being populated.
# Its final kind and children must not remain the initial plain placeholder.
m.decls.add Decl(kind: dkType, name: "Alias", typeBody: named("Recursive"))
m.decls.add Decl(kind: dkType, name: "Recursive",
                 typeBody: record(field("children", app("Seq", named("Alias")))))
let aliasPlan = glueFor(m, named("Recursive"))
doAssert aliasPlan.children[0].node.children[0].node.kind == gRecord
doAssert aliasPlan.children[0].node.children[0].node.owns

# Lowered recursive sums have Seq boxes: their graph has a genuine cycle.
m.decls.add Decl(kind: dkType, name: "Expr",
  typeBody: Type(kind: tkSum, variants: @[
    VariantDef(name: "Num", fields: @[field("value", named("int"))]),
    VariantDef(name: "Neg", fields: @[field("operand", app("Seq", named("Expr")))])]))
let tree = glueFor(m, named("Expr"))
doAssert tree.kind == gSum and tree.owns
doAssert tree.children[1].node.kind == gRecord
doAssert tree.children[1].node.children[0].node.kind == gSequence
doAssert tree.children[1].node.children[0].node.children[0].node == tree

# Scalar-only recursive graphs converge too; a cycle is not ownership by itself.
m.decls.add Decl(kind: dkType, name: "Cycle", typeBody: named("Cycle"))
doAssert not glueFor(m, named("Cycle")).owns
doAssert not glueFor(m, named("int")).owns
echo "OK: rule G type graph"

let slots = owningSlots(m, app("Nested", named("int")))
doAssert slots.len == 1 and slots[0].path == "inside.items"
doAssert slots[0].typ.kind == tkApp and slots[0].typ.args[0].name == "int"
let stringSlots = owningSlots(m, record(field("label", named("str")), field("xs", ints)))
doAssert stringSlots.len == 2
doAssert stringSlots[0].path == "label" and stringSlots[1].path == "xs"
