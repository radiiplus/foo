import std/strutils
import ../../src/diag/render
import ../../src/diag/engine
import ../../src/diag/code
import ../../src/diag/span

let diagnostics = newEngine()
diagnostics.setSource("constant value is @.", "main.iv")
diagnostics.emit(Code.Unexpected, Span(start: 18, `end`: 19, line: 1, col: 19), "unexpected character '@'")
diagnostics.suggestion("Remove the character")
let message = diagnostics.messages[0]

let short = render(message, options = RenderOptions(codes: true))
doAssert short.contains("main.iv:1:19")
doAssert short.contains("Code: FOO0000")
let verbose = render(message, options = RenderOptions(style: "verbose"))
doAssert verbose.contains("error[FOO0000]")
let json = render(message, options = RenderOptions(style: "json"))
doAssert json.contains("\"source\": \"foo\"")
echo "diagnostic render parity: ok"
