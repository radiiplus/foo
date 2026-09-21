import ../../src/diag/span

let location = Span(start: 2, `end`: 5, line: 3, col: 4)
let stored = range(location)
doAssert stored.start == Position(line: 2, character: 3)
doAssert stored.`end` == Position(line: 2, character: 6)

let calculated = range(Span(start: 2, `end`: 6), "a\nbc\ndef")
doAssert calculated.start == Position(line: 1, character: 0)
doAssert calculated.`end` == Position(line: 2, character: 1)
echo "span parity: ok"
