import ./span

type
  Note* = object
    span*: Span
    text*: string
    fix*: string
