import std/strutils
import ../../src/fmt/formatter

let source = "-- module comment\nstart(){\n  -- body comment\n  give nothing.\n}\n"
let formatted = formatSource(source)
doAssert formatted.contains("-- module comment")
doAssert formatted.contains("start()")
doAssert formatted.endsWith("\n")
doAssert formatSource(formatted) == formatted
let canonical = formatSource("start() { give nothing. }")
doAssert canonical == formatSource(canonical)
echo "formatter parity: ok"
