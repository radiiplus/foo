import std/[algorithm, json, os, sequtils, sets, strutils, tables]
import ../../src/diag/engine
import ../../src/lex/kind
import ../../src/lex/lexer
import ../../src/parse/parser
import ../../src/build/compiler as buildCompiler

type
  Fence = object
    path: string
    line: int
    language: string
    source: string
    expectedError: string
    contextual: bool
    project: string
    projectFile: string

proc fences(path: string): seq[Fence] =
  let source = readFile(path)
  var active = false
  var language = ""
  var expectedError = ""
  var pendingDirective = ""
  var pendingProject = ""
  var pendingFile = ""
  var opening = 0
  var body: seq[string]
  let lines = source.splitLines()
  for index in 0 ..< lines.len:
    let line = lines[index]
    if line.startsWith("```"):
      if active:
        result.add(Fence(path: path, line: opening, language: language,
          source: body.join("\n") & "\n", expectedError: expectedError,
          contextual: expectedError == "context", project: pendingProject,
          projectFile: pendingFile))
        active = false
        language = ""
        expectedError = ""
        pendingProject = ""
        pendingFile = ""
        body.setLen(0)
      else:
        active = true
        opening = index + 1
        language = line[3 .. ^1].strip().toLowerAscii()
        expectedError = pendingDirective
        pendingDirective = ""
      continue
    if active:
      body.add(line)
    else:
      let stripped = line.strip()
      if stripped == "<!-- snippet: context -->":
        pendingDirective = "context"
      elif stripped.startsWith("<!-- snippet: project ") and
          stripped.endsWith(" -->"):
        let values = stripped[22 ..< stripped.len - 4].splitWhitespace()
        if values.len != 2:
          raise newException(ValueError, path & ":" & $(index + 1) &
            ": project snippet needs a group and project-relative path")
        pendingProject = values[0]
        pendingFile = values[1]
      elif stripped.startsWith("<!-- snippet: error ") and
          stripped.endsWith(" -->"):
        pendingDirective = stripped[20 ..< stripped.len - 4].strip()
      elif stripped.len > 0:
        pendingDirective = ""
        pendingProject = ""
        pendingFile = ""
  if active:
    raise newException(ValueError, path & ":" & $opening &
      ": unclosed code fence")

let repository = currentSourcePath().parentDir().parentDir().parentDir()
let documentation = repository / "docs"
let packageScripts = parseJson(readFile(repository / "package.json"))["scripts"]
var paths: seq[string]
for path in walkDirRec(documentation):
  if path.endsWith(".md"): paths.add(path)
paths.sort()

var fooCount = 0
var jsonCount = 0
var shellCount = 0
var failures: seq[string]
for path in paths:
  for fence in fences(path):
    let location = relativePath(fence.path, repository).replace('\\', '/') &
      ":" & $fence.line
    case fence.language
    of "foo":
      inc fooCount
      let diagnostics = newEngine()
      diagnostics.setSource(fence.source, location)
      let tokens = newLexer(fence.source, diagnostics).lex()
      discard newParser(tokens, diagnostics).parse()
      if diagnostics.failed:
        for message in diagnostics.messages:
          failures.add(location & ": " & message.text)
      const removed = ["fallible", "integer 64", "unsigned 64", "decimal 64",
        "repeat until", "advance ", "reference to",
        " equals ", " does not equal ", " times ", " catch ", "mutable ",
        "break.", "continue.", "cleanup {", "finally {"]
      for spelling in removed:
        if spelling in fence.source:
          failures.add(location & ": removed spelling in FOO example: " & spelling.strip())
      for token in tokens:
        if token.kind != Kind.Ident: continue
        var compound = '_' in token.text
        for index in 1 ..< token.text.len:
          if token.text[index].isUpperAscii: compound = true
        if compound:
          failures.add(location & ": FOO names must be one word: " & token.text)
    of "json":
      inc jsonCount
      try:
        discard parseJson(fence.source)
      except JsonParsingError as error:
        failures.add(location & ": invalid JSON: " & error.msg)
    of "sh":
      inc shellCount
      const commands = ["add", "benchmark", "bind", "build", "check",
        "clean", "doctor", "info", "init", "install", "login", "new",
        "outdated", "publish", "remove", "run", "search", "test",
        "update", "watch"]
      for line in fence.source.splitLines():
        let command = line.strip()
        if command.len == 0 or command.startsWith("#") or
            command.startsWith("cd "): continue
        let words = command.splitWhitespace()
        if words.len >= 4 and words[0].startsWith("FOOSIGNKEY=") and
            words[1] == "npm" and words[2] == "run":
          if not packageScripts.hasKey(words[3]):
            failures.add(location & ": unknown npm script: " & command)
          continue
        if words.len >= 3 and words[0] == "npm" and words[1] == "run":
          if not packageScripts.hasKey(words[2]):
            failures.add(location & ": unknown npm script: " & command)
          continue
        if not command.startsWith("foo "):
          failures.add(location & ": unsupported shell example: " & command)
          continue
        if words.len < 2 or words[1] notin commands:
          failures.add(location & ": unknown FOO command: " & command)
    else: discard

if failures.len > 0:
  for failure in failures: stderr.writeLine(failure)
  quit("documentation snippet validation failed: " & $failures.len &
    " issue(s)", 1)

let output = repository / ".artifacts" / "docs" / "audit" /
  $getCurrentProcessId()
createDir(output)
let verbose = getEnv("FOO_DOC_AUDIT") == "1"
var checked = 0
var incomplete = 0
var expectedFailures = 0
var serial = 0
var grouped = initOrderedTable[string, seq[Fence]]()
for path in paths:
  for fence in fences(path):
    if fence.language == "foo" and fence.project.len > 0:
      if not grouped.hasKey(fence.project): grouped[fence.project] = @[]
      grouped[fence.project].add(fence)

var projectLocations = initHashSet[string]()
for name, projectFences in grouped:
  let projectRoot = output / ("project-" & name)
  createDir(projectRoot)
  writeFile(projectRoot / "project.json",
    "{\"schema\":1,\"name\":\"" & name &
    "\",\"language\":\"1\",\"source\":\"src\",\"requires\":\"base\",\"dependencies\":{}}\n")
  var entry = ""
  for fence in projectFences:
    let target = projectRoot / fence.projectFile
    createDir(parentDir(target))
    writeFile(target, fence.source)
    projectLocations.incl(fence.path & ":" & $fence.line)
    if fence.projectFile == "src/main.iv": entry = target
  if entry.len == 0:
    failures.add("project snippet '" & name & "' needs src/main.iv")
    continue
  try:
    discard buildCompiler.newCompiler(projectRoot).ir(entry)
    checked += projectFences.len
    if verbose: echo "PROJECT " & name
  except buildCompiler.Diagnostics as error:
    for message in error.diagnostics.messages:
      failures.add("project " & name & ":" & $message.span.line & ":" &
        $message.span.col & ": " & $message.code & ": " & message.text)
  except CatchableError as error:
    failures.add("project " & name & ": lowering failed: " & error.msg)

for path in paths:
  for fence in fences(path):
    if fence.language != "foo": continue
    inc serial
    let location = relativePath(fence.path, repository).replace('\\', '/') &
      ":" & $fence.line
    if fence.path & ":" & $fence.line in projectLocations: continue
    let snippet = output / ("snippet-" & $serial & ".iv")
    writeFile(snippet, fence.source)
    try:
      discard buildCompiler.newCompiler(repository).ir(snippet)
      if fence.contextual:
        failures.add(location & ": contextual snippet compiled; make it a complete example")
      elif fence.expectedError.len > 0:
        failures.add(location & ": expected " & fence.expectedError &
          " but the snippet compiled")
      else:
        inc checked
        if verbose: echo "CHECK " & location
    except buildCompiler.Diagnostics as error:
      if fence.contextual:
        let unexpected = error.diagnostics.messages.filterIt(
          $it.code notin ["Missing", "Absent"])
        if unexpected.len > 0:
          for message in unexpected:
            failures.add(location & ":" & $message.span.line & ":" &
              $message.span.col & ": " & $message.code & ": " & message.text)
        else:
          inc incomplete
          if verbose:
            echo "CONTEXT " & location
            for message in error.diagnostics.messages:
              echo "  " & $message.code & " " & $message.span.line & ":" &
                $message.span.col & ": " & message.text
      elif fence.expectedError.len > 0:
        if error.diagnostics.messages.anyIt($it.code == fence.expectedError):
          inc expectedFailures
          if verbose: echo "EXPECTED " & location & " " & fence.expectedError
        else:
          failures.add(location & ": expected " & fence.expectedError &
            ", got " & error.diagnostics.messages.mapIt($it.code).join(", "))
      else:
        for message in error.diagnostics.messages:
          failures.add(location & ":" & $message.span.line & ":" &
            $message.span.col & ": " & $message.code & ": " & message.text)
    except CatchableError as error:
      failures.add(location & ": lowering failed: " & error.msg)
      if verbose:
        let trace = getCurrentException().getStackTrace()
        if trace.len > 0: stderr.writeLine(trace)

if failures.len > 0:
  for failure in failures: stderr.writeLine(failure)
  quit("documentation snippet validation failed: " & $failures.len &
    " issue(s)", 1)

echo "documentation snippets: " & $fooCount & " FOO (" & $checked &
  " compiled, " & $incomplete & " contextual, " & $expectedFailures &
  " expected error), " & $jsonCount & " JSON, and " & $shellCount &
  " shell blocks validated"
