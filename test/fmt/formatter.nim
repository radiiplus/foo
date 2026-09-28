import std/strutils
import ../../src/fmt/formatter

let source = "-- file comment\nstart(){\n  -- body comment\n  give nothing.\n}\n"
let formatted = formatSource(source)
doAssert formatted.contains("-- file comment")
doAssert formatted.contains("start()")
doAssert formatted.endsWith("\n")
doAssert formatSource(formatted) == formatted
let canonical = formatSource("start() { give nothing. }")
doAssert canonical == formatSource(canonical)
let concise = formatSource("dynamic value of type integer is 8 multiply 2 subtract 4 divide 2.\nfunction identity(value integer) giving integer { give value. }")
doAssert concise.contains("dynamic value of type integer is 8 multiply 2 subtract 4 divide 2.")
doAssert concise.contains("function identity(value integer) giving integer")
let control = formatSource("define Identity as integer.\nwhile true { stop. skip. }")
doAssert control.contains("define Identity as integer.")
doAssert control.contains("stop.") and control.contains("skip.")
let natural = formatSource("function load() giving failable integer { give read() try. }\n" &
  "when count greater than or equal to 10 { display \"ready\". }")
doAssert natural.contains("give read() try.")
doAssert natural.contains("count greater than or equal to 10")
let indexed = formatSource("constant same is values at 1 is other at 1.")
doAssert indexed.contains("values at 1 is other at 1")
echo "formatter parity: ok"
