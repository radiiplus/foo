import ../../src/lex/lexer
import ../../src/lex/kind
import ../../src/lex/token
import ../../src/diag/engine
import ../../src/diag/code
import std/sequtils
import std/options
import ../../src/diag/span

let source = "constant answer is 1`000.\nconstant ratio is 12`345.6789.\n-- comment\nanswer."
let diagnostics = engine()
diagnostics.source(source, "lexer.iv")
let tokens = lexer(source, diagnostics).lex(true)

doAssert tokens[0].kind == Kind.Constant
doAssert tokens[1].kind == Kind.Ident
doAssert tokens[3].kind == Kind.Int
doAssert tokens[3].text == "1000"
doAssert tokens[3].spelling == "1`000"
doAssert tokens[4].kind == Kind.Dot
doAssert tokens[9].kind == Kind.Float
doAssert tokens[9].text == "12345.6789"
doAssert tokens[9].spelling == "12`345.6789"
doAssert tokens[^1].kind == Kind.Eof
doAssert tokens.allIt(it.span.file == "lexer.iv")
doAssert restore(tokens) == source
doAssert not diagnostics.failed

let legacy = engine()
legacy.source("constant old is 1_000.", "legacy.iv")
discard lexer(legacy.content, legacy).lex()
doAssert legacy.failed
doAssert legacy.messages.len == 1
doAssert legacy.messages[0].code == Code.Digit
doAssert legacy.messages[0].text == "Use backticks between digits instead of underscores"

let malformed = engine()
malformed.source("constant bad is 1``000.", "malformed.iv")
discard lexer(malformed.content, malformed).lex()
doAssert malformed.failed
doAssert malformed.messages.len == 1
doAssert malformed.messages[0].text == "Place backticks between digits"

let fractional = engine()
fractional.source("constant bad is 12`345.67`89.", "fractional.iv")
discard lexer(fractional.content, fractional).lex()
doAssert fractional.failed
doAssert fractional.messages.len == 1
doAssert fractional.messages[0].text == "Backticks can separate only the whole-number part"
let restored = @[
  Token(kind: Kind.Int, span: Span(start: 0, `end`: 2, line: 1, col: 1),
    text: "42", raw: some("42"), leading: some("  ")),
  Token(kind: Kind.Eof, span: Span(start: 2, `end`: 2, line: 1, col: 3),
    text: "", raw: some(""), leading: none(string))
]
doAssert restore(restored) == "  42"
doAssert phrases[0] == ["of", "type"]
echo "lexer parity: ok"
