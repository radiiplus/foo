import std/strutils
import std/sequtils

const architectures* = ["x86_64", "aarch64", "riscv64"]

proc jsonQuote(value: string): string =
  result = "\""
  for ch in value:
    case ch
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    of '\0': result.add("\\u0000")
    else: result.add(ch)
  result.add('"')

proc emit*(code: string; architecture: string; clobbers: seq[string] = @[]; global = false): string =
  if architecture notin architectures: raise newException(ValueError, "Assembly authoring is unavailable on " & architecture)
  if '\0' in code: raise newException(ValueError, "Assembly payload contains a NUL byte")
  for register in clobbers:
    if register.len == 0 or not register[0].isAlphaAscii or register.anyIt(not it.isAlphaNumeric):
      raise newException(ValueError, "Assembly clobbers must be register names")
  let quoted = jsonQuote(if global: code else: code.replace("%", "%%"))
  if global: return "__asm__(" & quoted & ");"
  var values = @["memory", "cc"]
  for register in clobbers:
    if register notin values: values.add(register)
  var encoded: seq[string]
  for register in values: encoded.add(jsonQuote(register))
  "__asm__ __volatile__(" & quoted & " : : : " & encoded.join(", ") & ");"
