import std/options
import ./kind
import ../diag/span

type
  NativeInfo* = object
    substrate*: string
    header*: Option[string]

  Token* = object
    kind*: Kind
    span*: Span
    text*: string
    native*: Option[NativeInfo]
    raw*: Option[string]
    leading*: Option[string]

proc restore*(tokens: seq[Token]): string =
  for token in tokens:
    if token.raw.isNone:
      raise newException(ValueError, "Restoring source requires lossless tokens")
    if token.leading.isSome:
      result.add(token.leading.get)
    result.add(token.raw.get)

const phrases* = [
  ["of", "type"], ["for", "each"], ["pointer", "to"], ["sequence", "of"],
  ["divided", "by"], ["less", "than"], ["greater", "than"], ["is", "not"]
]
