import std/[strutils, sequtils]
import ../ast/[node, print]
import ../diag/engine
import ../lex/[lexer, token]
import ../parse/parser

type Comment = object
  start: int
  text: string

proc comments(source: string): seq[Comment] =
  var offset = 0
  for line in source.splitLines:
    let trimmed = line.strip()
    if trimmed.startsWith("--"):
      result.add(Comment(start: offset + line.find('-'), text: trimmed))
    offset += line.len + 1

proc format*(program: Program; source = ""): string =
  if source.len == 0:
    return print(program).strip() & "\n"
  let found = comments(source)
  var cursor = 0
  var blocks: seq[string] = @[]
  for unit in program.units:
    for statement in unit.body.stmts:
      var prefix = ""
      for comment in found:
        if comment.start >= cursor and comment.start < statement.span.start:
          prefix.add(comment.text & "\n")
      prefix.add(print(statement, 0))
      blocks.add(prefix)
      cursor = statement.span.`end`
  result = blocks.join("\n").strip() & "\n"

proc formatSource*(source: string): string =
  let diagnostics = newEngine()
  let program = newParser(newLexer(source, diagnostics).lex(), diagnostics).parse()
  if diagnostics.failed: raise newException(ValueError, "Cannot format invalid source")
  format(program, source)
