import std/os
import ../../src/ast/node as ast
import ../../src/diag/engine
import ../../src/interop/expand
import ../../src/lex/lexer
import ../../src/ast/parser

let root = getTempDir() / "foo-interop-expand-test"
if dirExists(root): removeDir(root)
createDir(root)
writeFile(root / "foreign.h",
  "#if 0\nint excluded(int value);\n#else\nint increment(int value);\n#endif\n")
let source = "use c \"foreign.h\".\nstart { give nothing. }"
let diag = engine()
diag.source(source, root / "main.iv")
let program = parser(lexer(source, diag).lex(), diag).parse()
doAssert not diag.failed
expand(program, diag, root)
doAssert not diag.failed
doAssert program.units[0].body.stmts[0].tag == "function"
doAssert program.units[0].body.stmts[1].tag == "extern-function"
doAssert ast.External(program.units[0].body.stmts[1]).name.text == "increment"
removeDir(root)
echo "interop expand parity: ok"
