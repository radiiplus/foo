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

proc powerOfTwo(exponent: int): string =
  result = "1"
  for _ in 0 ..< exponent: result = doubled(result)

proc lessThan(left, right: string): bool =
  left.len < right.len or (left.len == right.len and left < right)

proc lessOrEqual(left, right: string): bool =
  left == right or lessThan(left, right)

proc divideByTwo(value: string): tuple[quotient: string, remainder: int] =
  var carry = 0
  for digit in value:
    let current = carry * 10 + ord(digit) - ord('0')
    if result.quotient.len > 0 or current div 2 > 0:
      result.quotient.add(char(ord('0') + current div 2))
    carry = current mod 2
  if result.quotient.len == 0: result.quotient = "0"
  result.remainder = carry

proc exactlyRepresentable(digits: string; precision: int): bool =
  if digits == "0": return true
  var value = digits
  var bits, trailing = 0
  var countingTrailing = true
  while value != "0":
    let divided = divideByTwo(value)
    inc bits
    if countingTrailing and divided.remainder == 0: inc trailing
    else: countingTrailing = false
    value = divided.quotient
  bits - trailing <= precision

proc substitute*(value: Type; replacements: Table[string, Type]): Type =
  if value == nil: return nil
  if value.kind == "named" and replacements.hasKey(value.name):
    return replacements[value.name]
  result = Type(kind: value.kind, name: value.name, width: value.width,
    constant: value.constant, abi: value.abi, length: value.length,
    layout: value.layout, value: value.value, borrows: value.borrows,
    generics: value.generics, constraints: value.constraints,
    fields: initOrderedTable[string, Type](),
    variants: initOrderedTable[string, Type]())
  if value.elem != nil: result.elem = substitute(value.elem, replacements)
  for parameter in value.params: result.params.add(substitute(parameter, replacements))
  if value.ret != nil: result.ret = substitute(value.ret, replacements)
  for argument in value.arguments: result.arguments.add(substitute(argument, replacements))
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
  of "Allocator": value != nil and value.kind == "opaque" and value.name == "Allocator"
  else: false

proc canCoerce*(fromType, toType: Type): Coercion =
  let yes = Coercion(ok: true, `type`: toType)
  let no = Coercion(ok: false, reason: "The value cannot be represented by the expected type")
  if typesEqual(fromType, toType): return yes
  if fromType.kind == "primitive" and fromType.name == "text" and toType.kind == "sequence" and toType.constant and toType.elem.kind == "primitive" and toType.elem.name == "byte": return yes
  if fromType.kind == "primitive" and fromType.name == "never": return yes
  if toType.kind == "optional" and fromType.kind == "primitive" and fromType.name == "nothing": return yes
  if (fromType.kind == "optional" and toType.kind == "optional") or (fromType.kind == "error" and toType.kind == "error"): return if canCoerce(fromType.elem, toType.elem).ok: yes else: no
  if toType.kind == "optional" or toType.kind == "error": return if canCoerce(fromType, toType.elem).ok: yes else: no
  if fromType.kind == "sequence" and toType.kind == "sequence" and not fromType.constant and toType.constant and typesEqual(fromType.elem, toType.elem): return yes
  if fromType.kind == "literal" and toType.kind == "primitive":
    if toType.name notin ["integer", "unsigned", "decimal", "byte"]: return no
    let value = decimal(fromType.value)
    if not value.valid: return no
    if toType.name == "decimal":
      try:
        let number = parseFloat((if value.negative: "-" else: "") & value.digits)
        let precision = if toType.width == 32: 24 else: 53
        return if number.classify in {fcInf, fcNegInf, fcNan}: no
          elif exactlyRepresentable(value.digits, precision): yes else: no
      except ValueError: return no
    let width = if toType.name == "byte": 8 elif toType.width > 0: toType.width else: 64
    if width < 1 or width > 128: return no
    if toType.name == "integer":
      let limit = powerOfTwo(width - 1)
      if (value.negative and lessOrEqual(value.digits, limit)) or
          (not value.negative and lessThan(value.digits, limit)): return yes
    elif not value.negative and lessThan(value.digits, powerOfTwo(width)):
      return yes
    return no
  if fromType.kind == "primitive" and toType.kind == "primitive":
    let left = if fromType.width > 0: fromType.width else: 64
    let right = if toType.width > 0: toType.width else: 64
    if fromType.name == toType.name and fromType.name in
        ["integer", "unsigned", "decimal"] and left <= right: return yes
    if fromType.name == "unsigned" and toType.name == "integer" and left < right:
      return yes
    if fromType.name in ["integer", "unsigned"] and toType.name == "decimal" and
        left <= (if right == 32: 24 else: 53): return yes
  no
