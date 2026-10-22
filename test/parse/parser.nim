import std/[sequtils, strutils]
import ../../src/lex/lexer
import ../../src/ast/parser
import ../../src/diag/engine
import ../../src/ast/node

let source = "constant answer is 42.\nstart {\n  give answer.\n}"
let diagnostics = engine()
diagnostics.source(source, "main.iv")
let tokens = lexer(source, diagnostics).lex()
let program = parser(tokens, diagnostics).parse()
doAssert program.units[0].body.stmts.len == 2
doAssert program.units[0].body.stmts[0].tag == "constant"
doAssert program.units[0].body.stmts[1].tag == "function"
doAssert not diagnostics.failed

let allocation = "start {\n  constant buffer is allocate 4 using owner try.\n}"
let issues = engine()
issues.source(allocation, "allocation.iv")
discard parser(lexer(allocation, issues).lex(), issues).parse()
doAssert not issues.failed

let natural = """
function connect giving failable integer { give 1. }
function load giving failable integer {
  constant socket is connect try.
  when socket greater than or equal to 10 { give socket. }
  when socket less than or equal to 0 { give 0. }
  display "connected" try.
  give socket.
}
"""
let notices = engine()
notices.source(natural, "natural.iv")
let tree = parser(lexer(natural, notices).lex(), notices).parse()
doAssert not notices.failed
let body = Function(tree.units[0].body.stmts[1]).body
doAssert Constant(body.stmts[0]).value.tag == "unary"
doAssert Unary(Constant(body.stmts[0]).value).op == "try"
doAssert Binary(`When`(body.stmts[1]).cond).op == "is at least"
doAssert Binary(`When`(body.stmts[2]).cond).op == "is at most"
doAssert Action(body.stmts[3]).value.tag == "unary"

let sample = """
function connect(host text, port integer default 443) giving integer {
  give port.
}
function total(values are sequence of integer) giving integer {
  dynamic result is 0.
  for each value in values { increase result by value. }
  give result.
}
function positive(value integer) when value greater than 0 giving integer {
  give value.
}
constant users are 2.
constant next is function giving integer { give 1. }.
connect(host "example.com", port 8080).
"""
let reports = engine()
reports.source(sample, "expressive.iv")
let parsed = parser(lexer(sample, reports).lex(), reports).parse()
doAssert not reports.failed
let unit = parsed.units[0].body
doAssert Function(unit.stmts[0]).params[1].default != nil
doAssert Function(unit.stmts[1]).params[0].variadic
doAssert Function(unit.stmts[2]).guard != nil
doAssert Constant(unit.stmts[3]).plural
doAssert Constant(unit.stmts[4]).value.tag == "closure"
let action = Action(unit.stmts[5])
doAssert action.value.tag == "call"
doAssert Call(action.value).names == @["host", "port"]

let content = "constant missing of type optional integer is null."
let optional = engine()
optional.source(content, "optional.iv")
let nullable = parser(lexer(content,
  optional).lex(), optional).parse()
doAssert not optional.failed
doAssert Constant(nullable.units[0].body.stmts[0]).value.tag == "null"

for removed in ["integer 64", "unsigned 64", "decimal 64"]:
  let representation = "constant value of type " & removed & " is 0."
  let precision = engine()
  precision.source(representation, "width.iv")
  discard parser(lexer(representation, precision).lex(),
    precision).parse()
  doAssert precision.failed
  doAssert precision.messages.anyIt("Use bare" in it.text)

for width in ["boolean 8", "text 16", "nothing 32"]:
  let representation = "constant value of type " & width & " is 0."
  let precision = engine()
  precision.source(representation, "width.iv")
  discard parser(lexer(representation, precision).lex(),
    precision).parse()
  doAssert precision.failed

for routine in [
    "function old(value of type integer) giving integer { give value. }",
    "function old(value integer) of type integer { give value. }",
    "constant old of type function(integer) of type integer is uninitialized.",
    "function old(value integer is 1) giving integer { give value. }",
    "function old value integer giving integer { give value. }",
    "function old() giving integer { give 1. }",
    "use \"c\" function old() giving integer."]:
  let function = engine()
  function.source(routine, "function.iv")
  discard parser(lexer(routine, function).lex(),
    function).parse()
  doAssert function.failed

let origin = "constant User(name, age) is user."
let unpacking = engine()
unpacking.source(origin, "destructure.iv")
let destructuring = parser(lexer(origin,
  unpacking).lex(), unpacking).parse()
doAssert not unpacking.failed
let destructure = Destructure(destructuring.units[0].body.stmts[0])
doAssert destructure.fields.len == 2
doAssert destructure.fields[0].text == "name"
doAssert destructure.bindings[1].text == "age"

let input = """
when score greater than 80 { display "high". }
otherwise when score greater than 50 { display "middle". }
otherwise { display "low". }
"""
let faults = engine()
faults.source(input, "branches.iv")
let branches = parser(lexer(input,
  faults).lex(), faults).parse()
doAssert not faults.failed
let branch = `When`(branches.units[0].body.stmts[0])
doAssert branch.`else`.tag == "when"
doAssert `When`(branch.`else`).`else`.tag == "block"

let modulo = "constant remainderValue is 5 remainder 2."
let remainder = engine()
remainder.source(modulo, "remainder.iv")
let residual = parser(lexer(modulo,
  remainder).lex(), remainder).parse()
doAssert not remainder.failed
let operand = Constant(residual.units[0].body.stmts[0]).value
doAssert operand.tag == "binary"
doAssert Binary(operand).op == "remainder"
echo "parser foundation parity: ok"
