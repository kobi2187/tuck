## Uninit field state (spec §4.8 amendment, 2026-08-14).
##
## A field a construction did not supply is a compile-time HOLE. Three rules:
##
##   1. never read  -> compiles. An untouched hole bothers no one.
##   2. read unset  -> error. This is the whole feature.
##   3. assigned    -> cleared, ordinary value from then on.
##
## The marker is `<uninit>[T]` on the FIELD's type inside the variable's
## synthesized record type. It rides with the value, so storing a partial
## record inside another record cannot launder it. It never reaches a backend:
## the declaration keeps its real field types and codegen reads declarations.
##
## This REPLACED a stricter reading of the 2026-07-09 ruling ("every field at
## construction"), which would have rejected the builder pattern — construct
## partial, fill by chain, then read. See ROADMAP.md.
import ../harness

const Cfg = """
type Config:
  port: int
  timeout: int
"""

proc run*(t: var T) =
  # --- rule 1: an unread hole is fine ------------------------------------
  t.src Cfg & """
fn main() -> int:
  let c = {port: 80} Config
  return c.port
"""
  t.okCheck "an unsupplied field nobody reads is legal"

  # --- rule 2: reading it is the error -----------------------------------
  t.src Cfg & """
fn main() -> int:
  let c = {port: 80} Config
  return c.timeout
"""
  t.badCheck "reading an unsupplied field is rejected", "uninit"

  # opacity: the read fails before any operator sees the value
  t.src Cfg & """
fn main() -> int:
  let c = {port: 80} Config
  return 5 + c.timeout
"""
  t.badCheck "an unsupplied field cannot be used in arithmetic", "uninit"

  # --- rule 3: assignment clears it --------------------------------------
  t.src Cfg & """
fn main() -> int:
  var c = {port: 80} Config
  c.timeout = 30
  return c.timeout
"""
  t.okCheck "assigning an unsupplied field fills it"

  t.src Cfg & """
fn main() -> int:
  var c = {port: 80} Config
  c ..timeout {30}
  return c.timeout
"""
  t.okCheck "a chain step fills an unsupplied field"

  # --- the record moves freely -------------------------------------------
  # Across a call boundary the question is sharper than compatibility can
  # answer: passing a partly-built record is fine unless the callee READS one
  # of the holes. Checked by scanning the callee's body at the call site, so
  # the error lands where the field can actually be supplied.
  t.src Cfg & """
fn show({c: Config}) -> int:
  return c.port

fn main() -> int:
  let c = {port: 80} Config
  return {c: c} show
"""
  t.okCheck "a partly-built record passes to a callee that reads only supplied fields"

  t.src Cfg & """
fn show({c: Config}) -> int:
  return c.timeout

fn main() -> int:
  let c = {port: 80} Config
  return {c: c} show
"""
  t.badCheck "passing a hole to a callee that reads it is rejected", "reads field"

  # Filling it first makes the same call legal.
  t.src Cfg & """
fn show({c: Config}) -> int:
  return c.timeout

fn main() -> int:
  var c = {port: 80} Config
  c.timeout = 30
  return {c: c} show
"""
  t.okCheck "filling the hole before the call makes it legal"

  t.src Cfg & """
fn main() -> int:
  let c = {port: 80, timeout: 30} Config
  return c.timeout
"""
  t.okCheck "a fully constructed record has no holes"

  # --- no laundering: the marker rides inside the value ------------------
  t.src Cfg & """
fn main() -> int:
  let c = {port: 80} Config
  let d = c
  return d.timeout
"""
  t.badCheck "a copy carries the hole", "uninit"

  t.src """
type Inner:
  a: int
  b: int

type Outer:
  name: str
  inner: Inner

fn main() -> int:
  let i = {a: 1} Inner
  let o = {name: "x", inner: i} Outer
  return o.inner.b
"""
  t.badCheck "storing a partial record in another does not launder it", "uninit"

  # --- objects behave the same -------------------------------------------
  t.src """
object Counter:
  hits: int
  label: str

fn main() -> int:
  let c = {hits: 0} Counter
  return c.hits
"""
  t.okCheck "an object's supplied field reads fine"

  t.src """
object Counter:
  hits: int
  label: str

fn main() -> str:
  let c = {hits: 0} Counter
  return c.label
"""
  t.badCheck "an object's unsupplied field is a hole", "uninit"

  # --- nothing leaks to the backend --------------------------------------
  t.src Cfg & """
fn main() -> int:
  var c = {port: 80} Config
  c.timeout = 30
  return c.timeout
"""
  t.omits "the marker never reaches emitted code", "uninit"
