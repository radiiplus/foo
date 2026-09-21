import std/strutils
import ../../src/ast/node as ast
import ../../src/diag/engine
import ../../src/lex/lexer
import ../../src/parse/parser

let source = """native zig { const value = .{ .answer = 42 }; }
native c { int answer(void) { return 42; } }
native asm { movq $42, %rax }
native c function add(value of type integer 32) of type integer 32 { return value + 1; }
asm { "nop" ::: "memory" }
native c { /* a closing brace } in a comment */ int nested(void) { return 1; } // another }
}
asm{ /* } */ movq $1, %rax }
"""
let diagnostics = newEngine()
diagnostics.setSource(source, "native.iv")
let program = newParser(newLexer(source, diagnostics).lex(), diagnostics).parse()
doAssert not diagnostics.failed, if diagnostics.messages.len > 0: diagnostics.messages[0].text else: "parse failed"
let statements = program.units[0].body.stmts
doAssert statements[0].tag == "native-zig"
doAssert ast.Native(statements[1]).substrate == "c"
doAssert ast.Native(statements[2]).substrate == "asm"
doAssert statements[3].tag == "extern-function"
doAssert ast.ExternFunction(statements[3]).native.substrate == "c"
doAssert statements[4].tag == "asm"
doAssert statements[5].tag == "native"
doAssert "nested" in ast.Native(statements[5]).code
doAssert statements[6].tag == "asm"
echo "parser native parity: ok"
