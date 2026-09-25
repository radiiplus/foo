import std/options
import std/sets
import std/strutils

let libraries = toHashSet([
  "arch", "atomic", "buffer", "compress", "crypto", "http", "json",
  "system", "testing", "unicode", "list", "memory", "stream", "sequence", "hashmap",
  "io", "fs", "net", "process", "thread", "time", "text"
])

proc binding*(name: string): Option[string] =
  if name == "c": return some("c")
  if name == "task": return some("runtime")
  if name in libraries: return some("runtime." & name)
  none(string)

proc provider*(abi: string): string =
  if abi == "runtime": return "task"
  if abi.startsWith("runtime."): return abi[8 .. ^1]
  abi
