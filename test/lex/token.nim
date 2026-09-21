import std/options
import ../../src/lex/token
import ../../src/lex/kind
import ../../src/diag/span

let sample = @[
  Token(kind: Kind.Int, span: Span(start: 0, `end`: 2, line: 1, col: 1), text: "42", raw: some("42"), leading: some("  ")),
  Token(kind: Kind.Eof, span: Span(start: 2, `end`: 2, line: 1, col: 3), text: "", raw: some(""), leading: none(string))
]

doAssert restore(sample) == "  42"
doAssert phrases[0] == ["of", "type"]
echo "token parity: ok"
