import std/sets
import std/strutils
import ../..//ir/node

const services* = ["io", "fs", "net", "process", "thread", "task", "time", "text"]

proc hosted*(module: Module): bool =
  for declaration in module.externs:
    if declaration.abi == "runtime" or
        (declaration.abi.startsWith("runtime.") and declaration.abi[8 .. ^1] in services):
      return true
  false

proc libraries*(target = ""): seq[string] =
  let platform = if target.len > 0: target
    elif defined(windows): "windows"
    elif defined(macosx): "macos"
    else: "linux"
  if platform.contains("windows") or platform.contains("win32"): @["ws2_32"]
  elif platform.contains("macos") or platform.contains("darwin"): @[]
  else: @["pthread"]
