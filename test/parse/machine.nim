import ../../src/ast/node as ast
import ../../src/diag/engine
import ../../src/lex/lexer
import ../../src/parse/parser

let source = """extern "C" function puts(value of type text) of type integer 32.
extern "C" function callback(value of type integer 32) giving integer 32 { give value. }
start() {
  atomic add counter by 1.
  bits set flags at position 4.
  bits clear flags at position 4.
  memory align buffer to 8.
  register rax is 44.
  constant pid is call system call 39 with 1, 2.
  try copy source into destination.
  constant count is words.length of source.
  clear destination.
}
"""

let diagnostics = newEngine()
diagnostics.setSource(source, "machine.iv")
let program = newParser(newLexer(source, diagnostics).lex(), diagnostics).parse()
doAssert not diagnostics.failed, if diagnostics.messages.len > 0: $diagnostics.messages[0].span.line & " " & diagnostics.messages[0].text else: "parse failed"

let declarations = program.units[0].body.stmts
doAssert declarations[0].tag == "extern-function"
doAssert ast.ExternFunction(declarations[0]).abi == "c"
doAssert declarations[1].tag == "function"
doAssert ast.Function(declarations[1]).abi == "c"

let body = ast.Function(declarations[2]).body.stmts
for index, operation in ["atomic", "set", "clear", "align", "register"]:
  doAssert body[index].tag == "machine"
  doAssert ast.Machine(body[index]).operation == operation
let system = ast.Machine(ast.Constant(body[5]).value)
doAssert system.operation == "system"
doAssert system.args.len == 2
doAssert ast.Try(body[6]).expr.tag == "call"
doAssert ast.Name(ast.Call(ast.Try(body[6]).expr).callee).text == "transfer"
let length = ast.Call(ast.Constant(body[7]).value)
doAssert ast.Field(length.callee).field.text == "length"
doAssert ast.Action(body[8]).value.tag == "call"

echo "parser machine and sentence parity: ok"
