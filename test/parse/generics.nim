import std/[os, sequtils]
import ../../src/ast/node as ast
import ../../src/diag/engine
import ../../src/lex/lexer
import ../../src/parse/parser

proc parseFile(path: string): ast.Program =
  let source = readFile(path)
  let diagnostics = newEngine()
  diagnostics.setSource(source, path)
  result = newParser(newLexer(source, diagnostics).lex(), diagnostics).parse()
  doAssert not diagnostics.failed, if diagnostics.messages.len > 0: path & ":" & $diagnostics.messages[0].span.line & " " & diagnostics.messages[0].text else: "parse failed"

proc parseSource(source: string): ast.Program =
  let diagnostics = newEngine()
  diagnostics.setSource(source, "declarations.iv")
  result = newParser(newLexer(source, diagnostics).lex(), diagnostics).parse()
  doAssert not diagnostics.failed, if diagnostics.messages.len > 0: $diagnostics.messages[0].span.line & " " & diagnostics.messages[0].text else: "parse failed"

let declarations = parseFile(currentSourcePath().parentDir.parentDir / "editor" / "cases" / "declarations.iv")
let statements = declarations.units[0].body.stmts
let box = ast.Alias(statements[0])
doAssert box.typeParams.len == 1
doAssert box.derives.traits.len == 2
let sort = ast.Function(statements[2])
doAssert sort.typeParams.len == 1
doAssert sort.constraints.len == 1

let library = parseFile(currentSourcePath().parentDir.parentDir.parentDir / "std" / "sequence.iv")
doAssert library.units[0].body.stmts.anyIt(it.tag == "extern-function" and ast.ExternFunction(it).typeParams.len == 1)

let layouts = parseSource("""#[repr(C)] type Point is record { x of type integer 32. }.
type Data is c union { number of type integer. }.
use sample as other.
function map[
  Input,
  Output
](
  value of type Input,
  callback of type function(
    Input
  ) of type Output
) of type Output
where
  Input is Copy,
  Output is Copy
{ give callback(value). }
""")
let layoutStatements = layouts.units[0].body.stmts
doAssert ast.Record(ast.Alias(layoutStatements[0]).body).layout == "c"
doAssert ast.Union(ast.Alias(layoutStatements[1]).body).layout == "c"
doAssert ast.Use(layoutStatements[2]).alias.text == "other"
let mapFunction = ast.Function(layoutStatements[3])
doAssert mapFunction.typeParams.len == 2
doAssert mapFunction.params.len == 2
doAssert mapFunction.constraints.len == 2
echo "parser generics parity: ok"
