import std/[algorithm, os, osproc, sequtils, strutils, tables]
import ../ast/node
import ../ast/doc as astDoc
import ../build/[compiler, project, files]
import ../diag/engine
import ../fmt/formatter
import ../lex/lexer
import ../parse/parser
import ../test/runner as testRunner

proc parseFile(path: string): Program =
  let source = readFile(path)
  let diag = newEngine()
  diag.setSource(source, path)
  result = newParser(newLexer(source, diag).lex(), diag).parse()
  if diag.failed: raise newException(ValueError, "Unable to parse " & path)

proc doc*(selection = ""; standard = "std"): string =
  var paths: seq[string]
  if selection.len > 0:
    paths = @[if selection.endsWith(".iv"): absolutePath(selection) else: standard / (selection & ".iv")]
  elif dirExists(standard):
    for kind, path in walkDir(standard):
      if kind == pcFile and path.endsWith(".iv"): paths.add(path)
    paths.sort()
  for path in paths:
    if not fileExists(path): raise newException(IOError, "No FOO library or source file named '" & selection & "'")
    result.add(astDoc.doc(parseFile(path)))

proc check*(entryFile: string; root = getCurrentDir(); options = ProjectOptions()): bool =
  newProject(root, options).check(entryFile)
  true

proc build*(entryFile = ""; root = getCurrentDir(); options = ProjectOptions()): Table[string, string] =
  newProject(root, options).build(entryFile)

proc run*(entryFile = ""; root = getCurrentDir(); options = ProjectOptions()) =
  let products = build(entryFile, root, options)
  if products.len != 1: raise newException(ValueError, "Choose an entry file when a project has multiple executables")
  let artifact = products.values.toSeq[0]
  if fileExists(artifact):
    let response = execCmdEx(quoteShell(artifact))
    if response.output.len > 0: stdout.write(response.output)
    if response.exitCode != 0: raise newException(OSError, response.output)

proc test*(root = getCurrentDir(); filter = ""; backend = "zig"; executor: TestExecutor = nil): seq[TestResult] =
  testRunner.runTests(root, filter, backend, executor)

proc fmt*(file: string): string =
  if not fileExists(file): raise newException(IOError, "File not found: " & file)
  result = formatter.format(parseFile(file), readFile(file))
  write(file, result)

proc cc*(args: seq[string]; compiler = "zig") =
  var command = quoteShell(compiler) & " cc"
  for argument in args: command.add(" " & quoteShell(argument))
  let response = execCmdEx(command)
  if response.exitCode != 0: raise newException(OSError, response.output)
