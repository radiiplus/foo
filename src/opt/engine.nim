import std/[algorithm, sequtils, strutils]

type
  Context* = object
    backend*: string
    target*: string
    cpu*: string
    mode*: string
    capability*: string
    portable*: bool
    knownSize*: int64
    sizeKnown*: bool
    overlapKnown*: bool
    overlaps*: bool

  Candidate* = object
    name*: string
    stage*: string
    contract*: string
    reason*: string
    priority*: int
    compatible*: bool
    evidenced*: bool
    fallback*: bool
    backends*: seq[string]
    targets*: seq[string]
    cpus*: seq[string]
    modes*: seq[string]
    minimum*: int64
    maximum*: int64
    overlap*: int

  Decision* = object
    operation*: string
    implementation*: string
    stage*: string
    contract*: string
    reason*: string
    fallback*: bool

proc candidate*(name, stage, contract, reason: string; priority: int;
    compatible = true; evidenced = true; fallback = false;
    backends: seq[string] = @[]; targets: seq[string] = @[];
    cpus: seq[string] = @[]; modes: seq[string] = @[];
    minimum = -1'i64; maximum = -1'i64; overlap = -1): Candidate =
  Candidate(name: name, stage: stage, contract: contract, reason: reason,
    priority: priority, compatible: compatible, evidenced: evidenced,
    fallback: fallback, backends: backends, targets: targets, cpus: cpus,
    modes: modes, minimum: minimum, maximum: maximum, overlap: overlap)

proc matches(candidate: Candidate; context: Context): bool =
  if not candidate.compatible or not candidate.evidenced: return false
  if candidate.backends.len > 0 and context.backend notin candidate.backends:
    return false
  if candidate.targets.len > 0 and not candidate.targets.anyIt(
      context.target.toLowerAscii().contains(it.toLowerAscii())):
    return false
  if candidate.cpus.len > 0 and context.cpu notin candidate.cpus: return false
  if candidate.modes.len > 0 and context.mode notin candidate.modes: return false
  if context.sizeKnown:
    if candidate.minimum >= 0 and context.knownSize < candidate.minimum: return false
    if candidate.maximum >= 0 and context.knownSize > candidate.maximum: return false
  elif candidate.minimum >= 0 or candidate.maximum >= 0:
    return false
  if candidate.overlap >= 0:
    if not context.overlapKnown: return false
    if (candidate.overlap == 1) != context.overlaps: return false
  true

proc choose*(operation, contract: string; context: Context;
    candidates: openArray[Candidate]): Decision =
  if candidates.len == 0:
    raise newException(ValueError,
      "Operation '" & operation & "' has no implementations")
  let fallbacks = candidates.filterIt(it.fallback and it.matches(context) and
    it.contract == contract)
  if fallbacks.len == 0:
    raise newException(ValueError,
      "Operation '" & operation & "' needs an evidenced compatible fallback")
  var eligible = candidates.filterIt(it.matches(context) and
    it.contract == contract)
  eligible.sort(proc(left, right: Candidate): int =
    result = cmp(right.priority, left.priority)
    if result == 0: result = cmp(left.name, right.name))
  if eligible.len > 1 and eligible[0].priority == eligible[1].priority and
      eligible[0].name != eligible[1].name:
    raise newException(ValueError,
      "Operation '" & operation & "' has ambiguous implementations '" &
      eligible[0].name & "' and '" & eligible[1].name & "'")
  let selected = eligible[0]
  Decision(operation: operation, implementation: selected.name,
    stage: selected.stage, contract: selected.contract,
    reason: selected.reason, fallback: selected.fallback)
