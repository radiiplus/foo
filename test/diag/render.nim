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

let colored = render(message, options = RenderOptions(color: true, codes: true))
doAssert colored.contains("\e[")
let plain = render(message, options = RenderOptions(color: false, codes: true))
doAssert not plain.contains("\e[")

let repeated = newEngine()
repeated.setSource("bad.\nok.\nbad.", "repeated.iv")
repeated.emit(Code.Unexpected, Span(start: 0, `end`: 3, line: 1, col: 1), "repeated failure")
repeated.emit(Code.Unexpected, Span(start: 9, `end`: 12, line: 3, col: 1), "repeated failure")
let grouped = renderAll(repeated.messages(), RenderOptions(color: false))
doAssert grouped.count("Repeated failure") == 1
doAssert grouped.contains("Affected lines: 1, 3")

let repeatedJson = renderAll(repeated.messages(), RenderOptions(style: "json"))
doAssert repeatedJson.count("\"severity\": \"error\"") == 2

let another = newEngine()
another.setSource("bad.", "other.iv")
another.emit(Code.Unexpected, Span(start: 0, `end`: 3, line: 7, col: 1), "repeated failure")
let acrossFiles = renderAll(@[repeated.messages()[0], another.messages()[0]],
  RenderOptions(color: false))
doAssert acrossFiles.contains("Affected locations:")
doAssert acrossFiles.contains("repeated.iv: line 1")
doAssert acrossFiles.contains("other.iv: line 7")
echo "diagnostic render parity: ok"
