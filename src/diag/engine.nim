import std/tables
import ./code
import ./span
import ./note

type
  RelatedSpan* = object
    span*: Span
    text*: string
    file*: string
    source*: string

  Fix* = object
    span*: Span
    text*: string
    title*: string
    file*: string
    source*: string

  Message* = object
    code*: Code
    span*: Span
    text*: string
    notes*: seq[Note]
    suggestion*: string
    context*: string
    relatedSpans*: seq[RelatedSpan]
    fixes*: seq[Fix]
    source*: string
    file*: string

  Engine* = ref object
    list: seq[Message]
    source: string
    file: string
    sources: Table[string, string]

proc newEngine*(): Engine =
  Engine(sources: initTable[string, string]())

proc register*(engine: Engine; file, source: string) =
  engine.sources[file] = source

proc setSource*(engine: Engine; source: string; file: string = "") =
  engine.source = source
  engine.file = file
  if file.len > 0: engine.register(file, source)

proc emit*(engine: Engine; code: Code; span: Span; text: string; context: string = "") =
  var message = Message(code: code, span: span, text: text, context: context)
  if span.file.len > 0 and engine.sources.hasKey(span.file):
    message.source = engine.sources[span.file]
  else:
    message.source = engine.source
  message.file = if span.file.len > 0: span.file else: engine.file
  engine.list.add(message)

proc fix*(engine: Engine; span: Span; text, title: string) =
  if engine.list.len == 0: return
  let file = if span.file.len > 0: span.file else: engine.file
  let source = if file.len > 0 and engine.sources.hasKey(file): engine.sources[file] else: engine.source
  engine.list[^1].fixes.add(Fix(span: span, text: text, title: title, file: file, source: source))

proc note*(engine: Engine; span: Span; text: string; fix: string = "") =
  if engine.list.len > 0: engine.list[^1].notes.add(Note(span: span, text: text, fix: fix))

proc suggestion*(engine: Engine; text: string) =
  if engine.list.len > 0: engine.list[^1].suggestion = text

proc related*(engine: Engine; span: Span; text: string; file: string = ""; source: string = "") =
  if engine.list.len == 0: return
  let resolvedFile = if file.len > 0: file elif span.file.len > 0: span.file else: engine.file
  let resolvedSource = if source.len > 0: source elif resolvedFile.len > 0 and engine.sources.hasKey(resolvedFile): engine.sources[resolvedFile] else: engine.source
  engine.list[^1].relatedSpans.add(RelatedSpan(span: span, text: text, file: resolvedFile, source: resolvedSource))

proc messages*(engine: Engine): seq[Message] = engine.list
proc failed*(engine: Engine): bool = engine.list.len > 0
proc getSource*(engine: Engine): string = engine.source
proc getFile*(engine: Engine): string = engine.file
