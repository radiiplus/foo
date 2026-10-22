import std/[os, sequtils]
import ../../src/ast/node as ast
import ../../src/diag/engine
import ../../src/lex/lexer
import ../../src/ast/parser

proc read(path: string): ast.Program =
  let source = readFile(path)
  let diagnostics = engine()
  diagnostics.source(source, path)
  result = parser(lexer(source, diagnostics).lex(), diagnostics).parse()
  doAssert not diagnostics.failed, if diagnostics.messages.len > 0: path & ":" & $diagnostics.messages[0].span.line & " " & diagnostics.messages[0].text else: "parse failed"

proc parse(source: string): ast.Program =
  let diagnostics = engine()
  diagnostics.source(source, "declarations.iv")
  result = parser(lexer(source, diagnostics).lex(), diagnostics).parse()
  doAssert not diagnostics.failed, if diagnostics.messages.len > 0: $diagnostics.messages[0].span.line & " " & diagnostics.messages[0].text else: "parse failed"

let declarations = read(currentSourcePath().parentDir.parentDir / "editor" / "cases" / "declarations.iv")
let statements = declarations.units[0].body.stmts
let functions = statements.filterIt(it.tag == "function").mapIt(ast.Function(it))
let choose = functions.filterIt(it.name.text == "choose")[0]
doAssert choose.generics.len == 1
let maximum = functions.filterIt(it.name.text == "maximum")[0]
doAssert maximum.generics.len == 1
doAssert maximum.constraints.len == 1

let library = read(currentSourcePath().parentDir.parentDir.parentDir / "lib" / "sequence.iv")
doAssert library.units[0].body.stmts.anyIt(it.tag == "extern-function" and ast.External(it).generics.len == 1)

let layouts = parse("""define Point as c record { x of type integer 32. }.
define Data as c union { number of type integer. }.
use sample as other.
function map[
  Input,
  Output
](
  value Input,
  callback function taking (
    Input
  ) giving Output
) giving Output
where
  Input is Copy,
  Output is Copy
{ give callback(value). }
""")
let members = layouts.units[0].body.stmts
doAssert ast.Record(ast.Alias(members[0]).body).layout == "c"
doAssert ast.Union(ast.Alias(members[1]).body).layout == "c"
doAssert ast.Use(members[2]).alias.text == "other"
let function = ast.Function(members[3])
doAssert function.generics.len == 2
doAssert function.params.len == 2
doAssert function.constraints.len == 2
echo "parser generics parity: ok"
