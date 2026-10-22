import std/strutils
import ../../src/lex/lexer
import ../../src/ast/parser
import ../../src/diag/engine
import ../../src/ast/node as ast

let source = """constant answer is 1 plus 2 multiply 3.
constant result is add(1, 2).
constant compared is 4 greater than or equal to 3.
constant storage is allocate 64 using arena.
constant asset is embed[byte]("asset.bin").
constant shape is reflect[integer 32].
constant shapeSize is reflect[integer 32].size.
constant item is values at 2.
constant specialized is make[integer 32](1).
constant reduced is digit(value remainder 16).
constant lanes of type vector[4, decimal 32] is uninitialized."""
let diagnostics = engine()
diagnostics.source(source, "expressions.iv")
let program = parser(lexer(source, diagnostics).lex(), diagnostics).parse()
let first = ast.Constant(program.units[0].body.stmts[0])
let sum = ast.Binary(first.value)
doAssert sum.op == "plus"
doAssert ast.Binary(sum.right).op == "times"
let second = ast.Constant(program.units[0].body.stmts[1])
doAssert ast.Call(second.value).args.len == 2
doAssert ast.Binary(ast.Constant(program.units[0].body.stmts[2]).value).op == "is at least"
doAssert ast.Constant(program.units[0].body.stmts[3]).value.tag == "allocation"
doAssert ast.Constant(program.units[0].body.stmts[4]).value.tag == "embed"
doAssert ast.Constant(program.units[0].body.stmts[5]).value.tag == "reflect"
doAssert ast.Constant(program.units[0].body.stmts[6]).value.tag == "field"
doAssert ast.Constant(program.units[0].body.stmts[7]).value.tag == "index"
doAssert ast.Call(ast.Constant(program.units[0].body.stmts[8]).value).types.len == 1
let reduced = ast.Call(ast.Constant(program.units[0].body.stmts[9]).value)
doAssert reduced.names == @[""]
doAssert ast.Binary(reduced.args[0]).op == "remainder"
doAssert ast.Constant(program.units[0].body.stmts[10]).`type`.tag == "vector"
doAssert not diagnostics.failed

let input = "eval { constant wordBytes is reflect[integer 32].size. verify wordBytes is 4. }"
let messages = engine()
messages.source(input, "assertion.iv")
let assertions = parser(lexer(input, messages).lex(),
  messages).parse()
let assertion = ast.Verify(ast.Evaluation(assertions.units[0].body.stmts[0]).body.stmts[1])
doAssert assertion.condition.tag == "binary"
doAssert not messages.failed


let concise = "define Identity as integer.\n" &
  "dynamic total is 20 subtract 4 multiply 2 divide 8.\n" &
  "constant safe is load fallback 0.\n" &
  "function tax(price decimal) giving decimal { give price. }"
let issues = engine()
issues.source(concise, "concise.iv")
let abbreviated = parser(lexer(concise, issues).lex(), issues).parse()
doAssert abbreviated.units[0].body.stmts[0].tag == "alias"
doAssert abbreviated.units[0].body.stmts[1].tag == "mutable"
doAssert ast.Binary(ast.Constant(abbreviated.units[0].body.stmts[2]).value).op == "catch"
doAssert ast.Function(abbreviated.units[0].body.stmts[3]).returns != nil
doAssert not issues.failed


# Explicit generic arguments must not discard named argument labels.
let origin = "constant named is make[unsigned](items values).\n" &
  "constant mixed is make[unsigned](1, size 2).\n" &
  "constant arithmetic is digit[unsigned](value remainder 16)."
let faults = engine()
faults.source(origin, "genericlabels.iv")
let generic = parser(lexer(origin, faults).lex(), faults).parse()
doAssert not faults.failed
let named = ast.Call(ast.Constant(generic.units[0].body.stmts[0]).value)
doAssert named.types.len == 1 and named.names == @["items"]
doAssert named.args[0].tag == "name"
doAssert ast.Call(ast.Constant(generic.units[0].body.stmts[1]).value).names == @["", "size"]
let arithmetic = ast.Call(ast.Constant(generic.units[0].body.stmts[2]).value)
doAssert arithmetic.names == @[""] and arithmetic.args[0].tag == "binary"
let content = "constant bad is make[unsigned](size 2, 1)."
let misordered = engine()
misordered.source(content, "misordered.iv")
discard parser(lexer(content, misordered).lex(), misordered).parse()
doAssert misordered.failed

echo "parser expression parity: ok"
