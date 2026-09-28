import std/[os, strutils]
import "../../src/interop/bind.nim" as binding
import ../../src/diag/engine
import ../../src/lex/lexer
import ../../src/parse/parser

let root = getTempDir() / "foo-interop-bind-test"
if dirExists(root): removeDir(root)
createDir(root)
let header = root / "foreign.h"
writeFile(header, "#define ANSWER 42\nint increment(int value);\n")
let options = BindOptions(cacheDir: root / "cache")
let first = binding.`bind`(header, options)
doAssert not first.cached
doAssert first.source.contains("constant ANSWER is 42.")
doAssert first.source.contains("extern \"C\" function increment(value integer 32) giving integer 32")
let diagnostics = newEngine()
diagnostics.setSource(first.source, first.bindingPath)
discard newParser(newLexer(first.source, diagnostics).lex(), diagnostics).parse()
doAssert not diagnostics.failed,
  if diagnostics.messages.len > 0: diagnostics.messages[0].text
  else: "generated binding did not parse"
let second = binding.`bind`(header, options)
doAssert second.cached
doAssert second.source == first.source
removeDir(root)
echo "interop bind parity: ok"
