import std/[algorithm, json, os, sequtils, sets, strutils, tables]
import ../../src/diag/engine
import ../../src/lex/kind
import ../../src/lex/lexer
import ../../src/ast/parser
import ../../src/build/compiler as compilation

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

proc commands(source: string): seq[string] =
  var pending = ""
  for line in source.splitLines():
    let part = line.strip()
    if part.len == 0 or part.startsWith("#"): continue
    if pending.len > 0: pending.add(" ")
    if part.endsWith("\\"):
      pending.add(part[0 ..< part.len-1].strip())
    else:
      pending.add(part)
      result.add(pending)
      pending.setLen(0)
  if pending.len > 0: raise newException(ValueError, "Unfinished shell continuation")

doAssert commands("clang -std=c11 " & $chr(92) & "\n  example.c -o example\nexample") == @["clang -std=c11 example.c -o example", "example"]
try:
  discard commands("clang " & $chr(92))
  doAssert false
except ValueError: discard

proc fences(path: string): seq[Fence] =
  let source = readFile(path)
  var active = false
  var language = ""
  var expectedError = ""
  var directive = ""
  var unfinished = ""
  var file = ""
  var opening = 0
  var body: seq[string]
  let lines = source.splitLines()
  for index in 0 ..< lines.len:
    let line = lines[index]
    if line.startsWith("```"):
      if active:
        result.add(Fence(path: path, line: opening, language: language,
          source: body.join("\n") & "\n", expectedError: expectedError,
          contextual: expectedError == "context", project: unfinished,
          projectFile: file))
        active = false
        language = ""
        expectedError = ""
        unfinished = ""
        file = ""
        body.setLen(0)
      else:
        active = true
        opening = index + 1
        language = line[3 .. ^1].strip().toLowerAscii()
        expectedError = directive
        directive = ""
      continue
    if active:
      body.add(line)
    else:
      let stripped = line.strip()
      if stripped == "<!-- snippet: context -->":
        directive = "context"
      elif stripped.startsWith("<!-- snippet: project ") and
          stripped.endsWith(" -->"):
        let values = stripped[22 ..< stripped.len - 4].splitWhitespace()
        if values.len != 2:
          raise newException(ValueError, path & ":" & $(index + 1) &
            ": project snippet needs a group and project-relative path")
        unfinished = values[0]
        file = values[1]
      elif stripped.startsWith("<!-- snippet: error ") and
          stripped.endsWith(" -->"):
        directive = stripped[20 ..< stripped.len - 4].strip()
      elif stripped.len > 0:
        directive = ""
        unfinished = ""
        file = ""
  if active:
    raise newException(ValueError, path & ":" & $opening &
      ": unclosed code fence")

let repository = currentSourcePath().parentDir().parentDir().parentDir()
let documentation = repository / "docs"
let scripts = parseJson(readFile(repository / "package.json"))["scripts"]
var paths: seq[string]
for path in walkDirRec(documentation):
  if path.endsWith(".md"): paths.add(path)
paths.sort()

var count = 0
var observations = 0
var shell = 0
var failures: seq[string]
for path in paths:
  for fence in fences(path):
    let location = relativePath(fence.path, repository).replace('\\', '/') &
      ":" & $fence.line
    case fence.language
    of "foo":
      inc count
      let diagnostics = engine()
      diagnostics.source(fence.source, location)
      let tokens = lexer(fence.source, diagnostics).lex()
      discard parser(tokens, diagnostics).parse()
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
      inc observations
      try:
        discard parseJson(fence.source)
      except JsonParsingError as error:
        failures.add(location & ": invalid JSON: " & error.msg)
    of "sh":
      inc shell
      const commands = ["add", "benchmark", "bind", "build", "check",
        "clean", "doctor", "info", "init", "install", "login", "new",
        "outdated", "path", "publish", "release", "remove", "run",
        "search", "sign", "link", "unlink", "test", "update", "watch"]
      var artifacts = initHashSet[string]()
      var logical: seq[string]
      try: logical = commands(fence.source)
      except ValueError as error: failures.add(location & ": " & error.msg)
      for line in logical:
        let command = line.strip()
        if command.len == 0 or command.startsWith("#") or
            command.startsWith("cd "): continue
        let words = command.splitWhitespace()
        if words.len >= 4 and words[0].startsWith("FOOSIGNER=") and
            words[1] == "npm" and words[2] == "run":
          if not scripts.hasKey(words[3]):
            failures.add(location & ": unknown npm script: " & command)
          continue
        if words.len >= 3 and words[0] == "npm" and words[1] == "run":
          if not scripts.hasKey(words[2]):
            failures.add(location & ": unknown npm script: " & command)
          continue
        if words.len >= 2 and words[0] == "node" and
            words[1] == "tools/benchmark.mjs":
          if not fileExists(repository / words[1]):
            failures.add(location & ": missing benchmark script: " & command)
          continue
        if words.len >= 4 and words[0] == "clang":
          # Static validation of the explicit native-frontend reproduction;
          # portable fragment sanitizers execute in their Linux platform group.
          let sources = words.filterIt(it.endsWith(".c"))
          let destination = words.find("-o")
          if "-std=c11" notin words or sources.len == 0 or destination < 0 or destination+1 >= words.len:
            failures.add(location & ": incomplete Clang C frontend example: " & command)
          else:
            for source in sources:
              if not fileExists(repository / source): failures.add(location & ": missing native source: " & source)
            artifacts.incl(words[destination+1])
          continue
        if words.len == 2 and words[0].startsWith("ASAN_OPTIONS="):
          if words[1] notin artifacts:
            failures.add(location & ": sanitizer command has no documented compiler output: " & command)
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

let output = getEnv("FOO_TEST_ARTIFACT_DIR", repository / ".artifacts" / "test") / "docs" / "audit" /
  $getCurrentProcessId()
createDir(output)
let verbose = getEnv("FOO_DOC_AUDIT") == "1"
var checked = 0
var incomplete = 0
var expected = 0
var serial = 0
var grouped = initOrderedTable[string, seq[Fence]]()
for path in paths:
  for fence in fences(path):
    if fence.language == "foo" and fence.project.len > 0:
      if not grouped.hasKey(fence.project): grouped[fence.project] = @[]
      grouped[fence.project].add(fence)

var locations = initHashSet[string]()
for name, fragments in grouped:
  let root = output / ("project-" & name)
  createDir(root)
  writeFile(root / "project.ivc", "capability \"project\"\nproject { name is " &
    $(%name) & " version is \"0.1.0\" source is \"src\" }\n")
  var entry = ""
  for fence in fragments:
    let target = root / fence.projectFile
    createDir(parentDir(target))
    writeFile(target, fence.source)
    locations.incl(fence.path & ":" & $fence.line)
    if fence.projectFile == "src/main.iv": entry = target
  if entry.len == 0:
    failures.add("project snippet '" & name & "' needs src/main.iv")
    continue
  try:
    discard compilation.compiler(root).ir(entry)
    checked += fragments.len
    if verbose: echo "PROJECT " & name
  except compilation.Diagnostics as error:
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
    if fence.path & ":" & $fence.line in locations: continue
    let snippet = output / ("snippet-" & $serial & ".iv")
    writeFile(snippet, fence.source)
    try:
      discard compilation.compiler(repository).ir(snippet)
      if fence.contextual:
        failures.add(location & ": contextual snippet compiled; make it a complete example")
      elif fence.expectedError.len > 0:
        failures.add(location & ": expected " & fence.expectedError &
          " but the snippet compiled")
      else:
        inc checked
        if verbose: echo "CHECK " & location
    except compilation.Diagnostics as error:
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
          inc expected
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

echo "documentation snippets: " & $count & " FOO (" & $checked &
  " compiled, " & $incomplete & " contextual, " & $expected &
  " expected error), " & $observations & " JSON, and " & $shell &
  " shell blocks validated"
