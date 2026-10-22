import ../../src/ast/node
import ../../src/ast/print
import ../../src/ast/parser as parsing
import ../../src/lex/lexer as scanning
import ../../src/diag/engine

let unsigned64 = Primitive(tag: "primitive", name: "unsigned", width: "64")
let answer = Function(
  tag: "function",
  public: true,
  name: Name(tag: "name", text: "answer"),
  returns: unsigned64,
  body: Block(tag: "block", stmts: @[
    Statement(Give(tag: "give", value: Integer(tag: "integer", value: "42")))
  ]))

doAssert print(answer) == "public function answer giving unsigned {\n  give 42.\n}"
doAssert print(Text(tag: "text", value: "left\nright")) == "(\"left\" plus newline plus \"right\")"
let source = "dynamic cpu_page of type unsigned aligned to 4096 in section \".percpu\" is 0."
let diagnostics = engine()
diagnostics.source(source, "memory.iv")
let syntax = parsing.parser(scanning.lexer(source, diagnostics).lex(),
  diagnostics).parse()
for message in diagnostics.messages: echo message.text
doAssert not diagnostics.failed
let placed = Mutable(syntax.units[0].body.stmts[0])
doAssert placed.alignment == 4096 and placed.section == ".percpu"
doAssert print(placed) == source
echo "ast print parity: ok"
