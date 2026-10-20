# compiler/shape_pool.nim
#
# Where a multi-module program declares its anonymous-record shapes.
import tables, strutils

type ShapePool* = ref object
  ## The shapes the program's modules asked for: name -> declaration text. One
  ## per emission of a program, shared by every context it writes files with.
  ##
  ## A shape is structural (two modules writing `{state, inc}` mean one type),
  ## but Odin and D types are nominal and a struct declared in each module
  ## would be a different one in each (#145). So a program of several modules
  ## declares every shape once, in a generated module called `module`, and
  ## every module reaches it like any other.
  module*: string
  defs*: OrderedTable[string, string]

proc newShapePool*(entry: string): ShapePool =
  ## The pool for the program whose entry module is `entry`. The module is named
  ## after it: programs emitted into one directory (the examples) each get
  ## their own, where one shared name would be overwritten by the last.
  ShapePool(module: "shapes_" & entry.replace("-", "_"),
            defs: initOrderedTable[string, string]())
