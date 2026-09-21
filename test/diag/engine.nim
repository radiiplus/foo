import ../../src/diag/engine
import ../../src/diag/code
import ../../src/diag/span

let diagnostics = newEngine()
diagnostics.setSource("bad", "main.iv")
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
doAssert diagnostics.messages[0].relatedSpans[0].source == "bad"
doAssert diagnostics.getSource == "bad"
echo "diagnostic engine parity: ok"
