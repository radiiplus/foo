import std/[algorithm, sequtils, strutils]

type
  Version* = object
    major*, minor*, patch*: int
  ConstraintKind* = enum
    Exact, Caret, Tilde
  Constraint* = object
    kind*: ConstraintKind
    version*: Version

proc parseVersion*(value: string): Version =
  let parts = value.split('.')
  if parts.len != 3:
    raise newException(ValueError, "Version must use major.minor.patch: " & value)
  var numbers: seq[int]
  for part in parts:
    if part.len == 0 or (part.len > 1 and part[0] == '0') or
        not part.allIt(it in {'0'..'9'}):
      raise newException(ValueError, "Invalid stable version: " & value)
    numbers.add(parseInt(part))
  Version(major: numbers[0], minor: numbers[1], patch: numbers[2])

proc parseConstraint*(value: string): Constraint =
  if value.len == 0: raise newException(ValueError, "Empty version constraint")
  var version = value
  result.kind = Exact
  if value[0] == '^':
    result.kind = Caret
    version = value[1 .. ^1]
  elif value[0] == '~':
    result.kind = Tilde
    version = value[1 .. ^1]
  result.version = parseVersion(version)

proc compare*(left, right: Version): int =
  if left.major != right.major: return cmp(left.major, right.major)
  if left.minor != right.minor: return cmp(left.minor, right.minor)
  cmp(left.patch, right.patch)

proc `$`*(version: Version): string =
  $version.major & "." & $version.minor & "." & $version.patch

proc satisfies*(version: Version; constraint: Constraint): bool =
  if compare(version, constraint.version) < 0: return false
  case constraint.kind
  of Exact:
    compare(version, constraint.version) == 0
  of Tilde:
    version.major == constraint.version.major and
      version.minor == constraint.version.minor
  of Caret:
    if constraint.version.major > 0:
      version.major == constraint.version.major
    elif constraint.version.minor > 0:
      version.major == 0 and version.minor == constraint.version.minor
    else:
      version.major == 0 and version.minor == 0 and
        version.patch == constraint.version.patch

proc satisfies*(version, constraint: string): bool =
  parseVersion(version).satisfies(parseConstraint(constraint))

proc select*(versions: seq[string]; constraints: seq[string]): string =
  var candidates: seq[Version]
  for value in versions:
    let version = parseVersion(value)
    if constraints.allIt(version.satisfies(parseConstraint(it))):
      candidates.add(version)
  candidates.sort(proc(left, right: Version): int = compare(right, left))
  if candidates.len > 0: $candidates[0] else: ""
