import std/[algorithm, math, strutils, tables]
import ./type

type Coercion* = object
  ok*: bool
  `type`*: Type
  reason*: string

proc decimal(value: string): tuple[valid, negative: bool, digits: string] =
  var raw = value.replace("_", "")
  if raw.len == 0: return
  if raw[0] in {'-', '+'}:
    result.negative = raw[0] == '-'
    raw = raw[1 .. ^1]
  if raw.len == 0: return
  for digit in raw:
    if digit notin {'0' .. '9'}: return
  var first = 0
  while first + 1 < raw.len and raw[first] == '0': inc first
  result.digits = raw[first .. ^1]
  if result.digits == "0": result.negative = false
  result.valid = true

proc doubled(value: string): string =
  var carry = 0
  for index in countdown(value.high, 0):
    let digit = (ord(value[index]) - ord('0')) * 2 + carry
    result.add(char(ord('0') + digit mod 10))
    carry = digit div 10
  if carry > 0: result.add(char(ord('0') + carry))
  result.reverse()

proc power(exponent: int): string =
  result = "1"
  for _ in 0 ..< exponent: result = doubled(result)

proc less(left, right: string): bool =
  left.len < right.len or (left.len == right.len and left < right)

proc bounded(left, right: string): bool =
  left == right or less(left, right)

proc halved(value: string): tuple[quotient: string, remainder: int] =
  var carry = 0
  for digit in value:
    let current = carry * 10 + ord(digit) - ord('0')
    if result.quotient.len > 0 or current div 2 > 0:
      result.quotient.add(char(ord('0') + current div 2))
    carry = current mod 2
  if result.quotient.len == 0: result.quotient = "0"
  result.remainder = carry

proc exact(digits: string; precision: int): bool =
  if digits == "0": return true
  var value = digits
  var bits, trailing = 0
  var counting = true
  while value != "0":
    let divided = halved(value)
    inc bits
    if counting and divided.remainder == 0: inc trailing
    else: counting = false
    value = divided.quotient
  bits - trailing <= precision

proc substitute*(value: Type; replacements: Table[string, Type]): Type =
  if value == nil: return nil
  if value.kind == "named" and replacements.hasKey(value.name):
    return replacements[value.name]
  result = Type(kind: value.kind, name: value.name, width: value.width,
    constant: value.constant, abi: value.abi, length: value.length,
    layout: value.layout, value: value.value, borrows: value.borrows,
    releases: value.releases,
    generics: value.generics, constraints: value.constraints,
    labels: value.labels, defaults: value.defaults,
    variadic: value.variadic,
    fields: initOrderedTable[string, Type](),
    variants: initOrderedTable[string, Type]())
  if value.elem != nil: result.elem = substitute(value.elem, replacements)
  for parameter in value.params: result.params.add(substitute(parameter, replacements))
  if value.ret != nil: result.ret = substitute(value.ret, replacements)
  for argument in value.arguments: result.arguments.add(substitute(argument, replacements))
  if result.arguments.len > 0:
    let bracket = result.name.find('[')
    if bracket >= 0:
      var names: seq[string]
      for argument in result.arguments: names.add(label(argument))
      result.name = result.name[0 ..< bracket] & "[" &
        names.join(", ") & "]"
  for name, field in value.fields: result.fields[name] = substitute(field, replacements)
  for name, variant in value.variants:
    result.variants[name] = if variant == nil: nil else: substitute(variant, replacements)

proc satisfies*(value: Type; trait: string): bool =
  case trait
  of "Equatable", "Hash":
    value != nil and value.kind == "primitive" and
      value.name in ["integer", "unsigned", "boolean", "byte", "character", "text", "nothing"]
  of "Ord":
    value != nil and value.kind == "primitive" and
      value.name in ["integer", "unsigned", "boolean", "byte", "character", "text"]
  of "Allocator": value != nil and value.kind == "opaque" and value.name == "allocator"
  else: false

proc coercion*(source, representation: Type): Coercion =
  let yes = Coercion(ok: true, `type`: representation)
  let no = Coercion(ok: false, reason: "The value cannot be represented by the expected type")
  if equal(source, representation): return yes
  if source.kind == "function" and representation.kind == "function" and
      source.abi == "runtime.codec" and representation.abi.len == 0 and
      source.params.len == representation.params.len and
      source.borrows == representation.borrows and
      source.releases == representation.releases and
      equal(source.ret, representation.ret):
    for index, parameter in source.params:
      if not equal(parameter, representation.params[index]): return no
    return yes
  if source.kind == "primitive" and source.name == "text" and representation.kind == "sequence" and representation.constant and representation.elem.kind == "primitive" and representation.elem.name == "byte": return yes
  if source.kind == "primitive" and source.name == "never": return yes
  if (source.kind == "optional" and representation.kind == "optional") or (source.kind == "error" and representation.kind == "error"): return if coercion(source.elem, representation.elem).ok: yes else: no
  if representation.kind == "optional" or representation.kind == "error": return if coercion(source, representation.elem).ok: yes else: no
  if source.kind == "sequence" and representation.kind == "sequence" and not source.constant and representation.constant and equal(source.elem, representation.elem): return yes
  if source.kind == "literal" and representation.kind == "primitive":
    if representation.name notin ["integer", "unsigned", "decimal", "byte"]: return no
    let value = decimal(source.value)
    if not value.valid: return no
    if representation.name == "decimal":
      try:
        let number = parseFloat((if value.negative: "-" else: "") & value.digits)
        let precision = if representation.width == 32: 24 else: 53
        return if number.classify in {fcInf, fcNegInf, fcNan}: no
          elif exact(value.digits, precision): yes else: no
      except ValueError: return no
    let width = if representation.name == "byte": 8 elif representation.width > 0: representation.width else: 64
    if width < 1 or width > 128: return no
    if representation.name == "integer":
      let limit = power(width - 1)
      if (value.negative and bounded(value.digits, limit)) or
          (not value.negative and less(value.digits, limit)): return yes
    elif not value.negative and less(value.digits, power(width)):
      return yes
    return no
  if source.kind == "primitive" and representation.kind == "primitive":
    let left = if source.width > 0: source.width else: 64
    let right = if representation.width > 0: representation.width else: 64
    if source.name == representation.name and source.name in
        ["integer", "unsigned", "decimal"] and left <= right: return yes
    if source.name == "unsigned" and representation.name == "integer" and left < right:
      return yes
    if source.name in ["integer", "unsigned"] and representation.name == "decimal" and
        left <= (if right == 32: 24 else: 53): return yes
  no
