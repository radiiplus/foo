import std/[algorithm, json, strutils]
import ../ast/doc
import ../ast/node
import ../diag/engine
import ../lex/lexer
import ../parse/parser

proc parseSource(source, path: string): Program =
  let diagnostics = newEngine()
  diagnostics.setSource(source, path)
  result = newParser(newLexer(source, diagnostics).lex(), diagnostics).parse()
  if diagnostics.failed: raise newException(ValueError, "Unable to index public API in " & path)

proc summary(source: string): string =
  var lines: seq[string]
  for line in source.splitLines:
    let value = line.strip()
    if value.len == 0:
      if lines.len > 0: break
      continue
    if not value.startsWith("--"): break
    let text = value.strip(chars = {'-', '!', ' '})
    if text.len > 0: lines.add(text)
  lines.join(" ")

proc moduleName(path: string): string =
  result = path.replace('\\', '/')
  if result.endsWith(".iv"): result.setLen(result.len - 3)
  if result.startsWith("src/"): result = result[4 .. ^1]

proc documentation(source: string; offset: int): string =
  if offset <= 0: return
  var lines = source[0 ..< min(offset, source.len)].splitLines()
  var comments: seq[string]
  var index = lines.high
  while index >= 0:
    var line = lines[index].strip()
    if line.len == 0:
      dec index
      continue
    if not line.startsWith("--"): break
    if line.startsWith("---"): line = line[3 .. ^1].strip()
    else: line = line[2 .. ^1].strip()
    if line.startsWith("!"): line = line[1 .. ^1].strip()
    if line.endsWith("---"): line = line[0 ..< line.len - 3].strip()
    if line.len > 0: comments.add(line)
    dec index
  comments.reverse()
  comments.join(" ")

proc publicApi*(source: JsonNode): JsonNode =
  result = %*{"schema": "foo.api/v1", "modules": newJArray()}
  if source == nil or source.kind != JObject or source.getOrDefault("files").kind != JArray: return
  for file in source["files"]:
    let path = file.getOrDefault("path").getStr()
    if not path.endsWith(".iv"): continue
    let content = file.getOrDefault("content").getStr()
    let parsed = parseSource(content, path)
    var items = newJArray()
    for item in publicItems(parsed):
      items.add(%*{"kind": item.kind, "name": item.name,
        "declaration": item.declaration,
        "documentation": documentation(content, item.start)})
    result["modules"].add(%*{"name": moduleName(path), "path": path,
      "summary": summary(content), "items": items})
