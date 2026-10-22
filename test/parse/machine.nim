import ../../src/ast/node as ast
import ../../src/diag/engine
import ../../src/lex/lexer
import ../../src/ast/parser

let source = """extern "C" function puts(value text) giving integer 32.
extern "C" function callback(value integer 32) giving integer 32 { give value. }
start {
  atomic add counter by 1.
  bits set flags at position 4.
  bits clear flags at position 4.
  bits toggle flags at position 4.
  memory align buffer to 8.
  register rax is 44.
  constant pid is call system call 39 with 1, 2.
  copy source into destination try.
  constant count is words.length of source.
  clear destination.
}
"""

let diagnostics = engine()
diagnostics.source(source, "machine.iv")
let program = parser(lexer(source, diagnostics).lex(), diagnostics).parse()
doAssert not diagnostics.failed, if diagnostics.messages.len > 0: $diagnostics.messages[0].span.line & " " & diagnostics.messages[0].text else: "parse failed"

let declarations = program.units[0].body.stmts
doAssert declarations[0].tag == "extern-function"
doAssert ast.External(declarations[0]).abi == "c"
doAssert declarations[1].tag == "function"
doAssert ast.Function(declarations[1]).abi == "c"

let body = ast.Function(declarations[2]).body.stmts
for index, operation in ["atomic", "set", "clear", "toggle", "align", "register"]:
  doAssert body[index].tag == "machine"
  doAssert ast.Machine(body[index]).operation == operation
let system = ast.Machine(ast.Constant(body[6]).value)
doAssert system.operation == "system"
doAssert system.args.len == 2
let copied = ast.Unary(ast.Action(body[7]).value)
doAssert copied.op == "try"
doAssert copied.operand.tag == "call"
doAssert ast.Name(ast.Call(copied.operand).callee).text == "transfer"
let length = ast.Call(ast.Constant(body[8]).value)
doAssert ast.Field(length.callee).field.text == "length"
doAssert ast.Action(body[9]).value.tag == "call"

let input = """define Device as record {
  data of type pointer to unsigned 32 with exact access.
}.
function boot for startup without setup using feature "sse2" keeping call { }
function irq for interrupt { }
function pagefault for interrupt with error code { }
function hypervisor for interrupt at el2 { }
function monitor for interrupt at el3 { }
"""
let issues = engine()
issues.source(input, "field.iv")
let member = parser(lexer(input, issues).lex(),
  issues).parse()
doAssert not issues.failed
let alias = ast.Alias(member.units[0].body.stmts[0])
let field = ast.Record(alias.body).fields[0]
doAssert field.attributes == @["volatile"]
let boot = ast.Function(member.units[0].body.stmts[1])
doAssert boot.attributes == @["start", "naked", "target_feature(\"sse2\")", "noinline"]
doAssert ast.Function(member.units[0].body.stmts[2]).attributes == @["interrupt"]
doAssert ast.Function(member.units[0].body.stmts[3]).attributes ==
  @["interrupt_error_code"]
doAssert ast.Function(member.units[0].body.stmts[4]).attributes ==
  @["interrupt_el2"]
doAssert ast.Function(member.units[0].body.stmts[5]).attributes ==
  @["interrupt_el3"]

echo "parser machine and sentence parity: ok"
