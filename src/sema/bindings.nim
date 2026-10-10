import std/options
import std/sets
import std/strutils

let libraries = toHashSet([
  "arch", "atomic", "binary", "buffer", "checksum", "codec", "compress", "cpu", "topology", "platform", "crypto", "gpu", "vulkan", "http", "json",
  "system", "testing", "unicode", "list", "memory", "stream", "sequence", "table",
  "io", "fs", "vm", "net", "tls", "process", "resource", "ring", "bloom", "dylib", "thread", "time", "timer", "text", "metric", "trace", "limit"
])

proc binding*(name: string): Option[string] =
  if name == "task": return some("runtime")
  if name in libraries: return some("runtime." & name)
  none(string)

proc provider*(abi: string): string =
  if abi == "runtime": return "task"
  if abi.startsWith("runtime."): return abi[8 .. ^1]
  abi
