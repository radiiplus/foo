import std/strutils
import ../../src/diag/render
import ../../src/diag/engine
import ../../src/diag/code
import ../../src/diag/span
import ../../src/diag/palette

let diagnostics = engine()
diagnostics.source("constant value is @.", "main.iv")
diagnostics.emit(Code.Unexpected, Span(start: 18, `end`: 19, line: 1, col: 19), "unexpected character '@'")
diagnostics.suggestion("Remove the character")
let message = diagnostics.messages[0]

let short = render(message, options = Style(codes: true))
doAssert short.contains("main.iv:1:19")
doAssert short.contains("Code: FOO0000")
let verbose = render(message, options = Style(style: "verbose"))
doAssert verbose.contains("error[FOO0000]")
let json = render(message, options = Style(style: "json"))
doAssert json.contains("\"source\": \"foo\"")

let colored = render(message, options = Style(color: true, codes: true))
doAssert colored.contains("\e[")
let plain = render(message, options = Style(color: false, codes: true))
doAssert not plain.contains("\e[")

let repeated = engine()
repeated.source("bad.\nok.\nbad.", "repeated.iv")
repeated.emit(Code.Unexpected, Span(start: 0, `end`: 3, line: 1, col: 1), "repeated failure")
repeated.emit(Code.Unexpected, Span(start: 9, `end`: 12, line: 3, col: 1), "repeated failure")
let grouped = render(repeated.messages(), Style(color: false))
doAssert grouped.count("Repeated failure") == 1
doAssert grouped.contains("Affected lines: 1, 3")

let repetition = render(repeated.messages(), Style(style: "json"))
doAssert repetition.count("\"severity\": \"error\"") == 2

let another = engine()
another.source("bad.", "other.iv")
another.emit(Code.Unexpected, Span(start: 0, `end`: 3, line: 7, col: 1), "repeated failure")
let files = render(@[repeated.messages()[0], another.messages()[0]],
  Style(color: false))
doAssert files.contains("Affected locations:")
doAssert files.contains("repeated.iv: line 1")
doAssert files.contains("other.iv: line 7")
doAssert shade("info", 1) == "\e[34m"
doAssert shade("error", 24) == "\e[38;2;255;56;100m"
echo "diagnostic render parity: ok"
