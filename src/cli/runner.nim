import std/[algorithm, os, osproc, sequtils, strutils, tables]
import ../ast/node
import ../ast/doc as documentation
import ../build/[project, files, options]
import ../diag/engine
import ../ast/print as formatter
import ../lex/lexer
import ../ast/parser
import ../test/runner as testing

proc read(path: string): Program =
  let source = readFile(path)
  let diag = engine()
  diag.source(source, path)
  result = parser(lexer(source, diag).lex(), diag).parse()
  if diag.failed: raise newException(ValueError, "Unable to parse " & path)

proc doc*(selection = ""; standard = "lib"): string =
  var paths: seq[string]
  if selection.len > 0:
    paths = @[if selection.endsWith(".iv"): absolutePath(selection) else: standard / (selection & ".iv")]
  elif dirExists(standard):
    for kind, path in walkDir(standard):
      if kind == pcFile and path.endsWith(".iv"): paths.add(path)
    paths.sort()
  for path in paths:
    if not fileExists(path): raise newException(IOError, "No FOO library or source file named '" & selection & "'")
    result.add(documentation.doc(read(path)))

proc check*(location: string; root = getCurrentDir(); options = Settings()): bool =
  project(root, options).check(location)
  true

proc build*(location = ""; root = getCurrentDir(); options = Settings()): Table[string, string] =
  project(root, options).build(location)

proc run*(location = ""; root = getCurrentDir(); options = Settings()) =
  let products = project(root, options).build(location, executable = true)
  if products.len != 1: raise newException(ValueError, "Choose an entry file when a project has multiple executables")
  let artifact = products.values.toSeq[0]
  if fileExists(artifact):
    let response = execCmdEx(quoteShell(artifact))
    if response.output.len > 0: stdout.write(response.output)
    if response.exitCode != 0: raise newException(OSError, response.output)

proc test*(root = getCurrentDir(); filter = ""; backend = "qbe";
    executor: Executor = nil; progress: Observer = nil;
    mode = "dev"): seq[Result] =
  testing.run(root, filter, backend, executor, progress, mode)

proc fmt*(file: string): string =
  if not fileExists(file): raise newException(IOError, "File not found: " & file)
  result = formatter.format(read(file), readFile(file))
  write(file, result)

proc cc*(args: seq[string]; compiler = "clang") =
  var command = quoteShell(compiler)
  for argument in args: command.add(" " & quoteShell(argument))
  let response = execCmdEx(command)
  if response.exitCode != 0: raise newException(OSError, response.output)
