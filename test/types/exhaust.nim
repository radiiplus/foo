import std/strutils
import ../../src/types/exhaust
import ../../src/types/type as types
import ../../src/ast/node as ast
import ../../src/diag/engine
import ../../src/diag/span
import ../../src/diag/code

let diagnostics = newEngine()
let boolean = types.Type(kind: "primitive", name: "boolean")
let trueCase = ast.Case(tag: "case", pattern: ast.True(tag: "true"))
checkExhaustiveness(boolean, @[trueCase], Span(line: 1, col: 1), diagnostics)
doAssert diagnostics.failed
doAssert diagnostics.messages[0].code == Code.NonExhaustive
echo "exhaustiveness parity: ok"
