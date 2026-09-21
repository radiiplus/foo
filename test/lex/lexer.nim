import ../../src/lex/lexer
import ../../src/lex/kind
import ../../src/lex/token
import ../../src/diag/engine

let source = "constant answer is 1_000.\n-- comment\nanswer."
let diagnostics = newEngine()
diagnostics.setSource(source)
let tokens = newLexer(source, diagnostics).lex(true)

doAssert tokens[0].kind == Kind.Constant
doAssert tokens[1].kind == Kind.Ident
doAssert tokens[3].kind == Kind.Int
doAssert tokens[4].kind == Kind.Dot
doAssert tokens[^1].kind == Kind.Eof
doAssert restore(tokens) == source
doAssert not diagnostics.failed
echo "lexer parity: ok"
