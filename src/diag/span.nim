import std/strutils

type
  Span* = object
    start*: int
    `end`*: int
    line*: int
    col*: int
    file*: string

  Position* = object
    line*: int
    character*: int

  SourceRange* = object
    start*: Position
    `end`*: Position

proc range*(span: Span; source: string = ""): SourceRange =
  if source.len > 0:
    proc position(offset: int): Position =
      let bounded = max(0, min(offset, source.len))
      let prefix = source[0 ..< bounded]
      let lines = prefix.split('\n')
      Position(line: lines.len - 1, character: lines[^1].len)
    result.start = position(span.start)
    result.`end` = position(span.`end`)
  else:
    result.start = Position(line: max(0, span.line - 1), character: max(0, span.col - 1))
    result.end = Position(
      line: max(0, span.line - 1),
      character: max(0, span.col - 1) + max(0, span.`end` - span.start))
