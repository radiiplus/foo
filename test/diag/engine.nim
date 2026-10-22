import ../../src/diag/engine
import ../../src/diag/code
import ../../src/diag/span

let diagnostics = engine()
diagnostics.source("bad", "main.iv")
let location = Span(start: 0, `end`: 3, line: 1, col: 1)
diagnostics.emit(Code.Invalid, location, "invalid input")
diagnostics.note(location, "related note")
diagnostics.suggestion("replace it")
diagnostics.fix(location, "good", "Replace input")
diagnostics.related(location, "same location")

doAssert diagnostics.failed
doAssert diagnostics.messages.len == 1
doAssert diagnostics.messages[0].notes[0].text == "related note"
doAssert diagnostics.messages[0].fixes[0].file == "main.iv"
doAssert diagnostics.messages[0].related[0].source == "bad"
doAssert diagnostics.content == "bad"
block:
  let location = Span(start: 2, `end`: 5, line: 3, col: 4)
  let stored = range(location)
  doAssert stored.start == Position(line: 2, character: 3)
  doAssert stored.`end` == Position(line: 2, character: 6)
  let calculated = range(Span(start: 2, `end`: 6), "a\nbc\ndef")
  doAssert calculated.start == Position(line: 1, character: 0)
  doAssert calculated.`end` == Position(line: 2, character: 1)
echo "diagnostic engine parity: ok"
