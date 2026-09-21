import std/os
import ../../src/diag/engine
import ../../src/interop/expand
import ../../src/lex/lexer
import ../../src/parse/parser

let root = getTempDir() / "foo-interop-expand-test"
if dirExists(root): removeDir(root)
createDir(root)
writeFile(root / "foreign.h", "int increment(int value);\n")
let source = "use c \"foreign.h\".\nstart() { give nothing. }"
let diag = newEngine()
diag.setSource(source, root / "main.iv")
let program = newParser(newLexer(source, diag).lex(), diag).parse()
doAssert not diag.failed
expand(program, diag, root)
doAssert not diag.failed
doAssert program.units[0].body.stmts[0].tag == "function"
doAssert program.units[0].body.stmts[1].tag == "extern-function"
removeDir(root)
echo "interop expand parity: ok"
