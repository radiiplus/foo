import std/tables
import std/strutils
import std/sequtils
import ../ast/node as ast
import ../diag/engine
import ../diag/code
import ../diag/span
import ./type as types

proc checkExhaustiveness*(value: types.Type; cases: seq[ast.Case]; location: Span; diagnostics: Engine) =
  var covered = initTable[string, ast.Case]()
  var wildcard: ast.Case
  for arm in cases:
    let pattern = arm.pattern
    let key = if pattern.tag == "name": ast.Name(pattern).text elif pattern.tag == "variant-pattern": ast.VariantPattern(pattern).name.text elif pattern.tag == "integer": ast.Integer(pattern).value else: pattern.tag
    let previous = if wildcard != nil: wildcard elif key in covered: covered[key] else: nil
    if previous != nil:
      diagnostics.emit(Code.UnreachableCase, arm.span, "An earlier case already covers this value")
      diagnostics.related(previous.span, "Covered here")
    if arm.guard == nil:
      if pattern.tag == "wildcard": wildcard = arm else: covered[key] = arm
  if wildcard != nil: return
  var required: seq[string]
  if value.kind == "choice":
    for variant in value.variants.keys: required.add(variant)
  elif value.kind == "primitive" and value.name == "boolean": required = @["true", "false"]
  elif value.kind == "primitive" and value.name == "nothing": required = @["nothing"]
  if required.len == 0 or required.anyIt(it notin covered):
    var missing: seq[string]
    for name in required:
      if name notin covered: missing.add(name)
    diagnostics.emit(Code.NonExhaustive, location, if required.len > 0: "match is not exhaustive: missing cases for " & missing.join(", ") else: "This match needs an unguarded anything case")
    diagnostics.suggestion("Add a case for every remaining value")
