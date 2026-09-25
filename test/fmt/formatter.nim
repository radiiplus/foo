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
let concise = formatSource("mutable value of type integer is 8 times 2 minus 4 divided by 2.\nfunction identity(value of type integer) of type integer { give value. }")
doAssert concise.contains("dynamic value of type integer is 8 multiply 2 subtract 4 divide 2.")
doAssert concise.contains("function identity(value integer) giving integer")
let renamed = formatSource("type UserID is integer 64.\nwhile true { break. continue. }")
doAssert renamed.contains("define UserID as integer 64.")
doAssert renamed.contains("stop.") and renamed.contains("skip.")
let natural = formatSource("function load() giving fallible integer { give try read(). }\n" &
  "when count is at least 10 { display \"ready\". }")
doAssert natural.contains("give read() try.")
doAssert natural.contains("count greater than or equal to 10")
echo "formatter parity: ok"
