import std/strutils
import ../../src/ast/node as ast
import ../../src/diag/engine
import ../../src/lex/lexer
import ../../src/parse/parser

let source = """native c { int answer(void) { return 42; } }
native asm { movq $42, %rax }
native c function add(value integer 32) giving integer 32 { return value + 1; }
native c { /* a closing brace } in a comment */ int nested(void) { return 1; } // another }
}
"""
let diagnostics = newEngine()
diagnostics.setSource(source, "native.iv")
let program = newParser(newLexer(source, diagnostics).lex(), diagnostics).parse()
doAssert not diagnostics.failed, if diagnostics.messages.len > 0: diagnostics.messages[0].text else: "parse failed"
let statements = program.units[0].body.stmts
doAssert ast.Native(statements[0]).substrate == "c"
doAssert ast.Native(statements[1]).substrate == "asm"
doAssert statements[2].tag == "extern-function"
doAssert ast.ExternFunction(statements[2]).native.substrate == "c"
doAssert statements[3].tag == "native"
doAssert "nested" in ast.Native(statements[3]).code
echo "parser native parity: ok"
