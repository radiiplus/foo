import ../../src/lex/lexer
import ../../src/parse/parser
import ../../src/diag/engine
import ../../src/ast/node as ast

let source = """constant answer is 1 plus 2 times 3.
constant result is add(1, 2).
constant compared is 4 is at least 3.
constant storage is allocate 64 using arena.
constant asset is embed[byte]("asset.bin").
constant shape is reflect[integer 32]().
constant item is values at 2.
constant specialized is make[integer 32](1).
constant lanes of type vector[4, decimal 32] is uninitialized."""
let diagnostics = newEngine()
diagnostics.setSource(source, "expressions.iv")
let program = newParser(newLexer(source, diagnostics).lex(), diagnostics).parse()
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
doAssert ast.Constant(program.units[0].body.stmts[6]).value.tag == "index"
doAssert ast.Call(ast.Constant(program.units[0].body.stmts[7]).value).types.len == 1
doAssert ast.Constant(program.units[0].body.stmts[8]).`type`.tag == "vector"
doAssert not diagnostics.failed
echo "parser expression parity: ok"
