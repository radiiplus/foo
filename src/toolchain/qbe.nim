import std/os
import ../pkg/cache

proc selected(variable, fallback: string): string =
  let value = getEnv(variable)
  cache.executable(if value.len > 0: value else: fallback)

proc qbe*(): string =
  let local = getAppDir() / (when defined(windows): "qbe.exe" else: "qbe")
  selected("FOO_QBE", if fileExists(local): local else: "qbe")
proc cc*(): string =
  when defined(windows):
    let local = getAppDir() / "tcc.exe"
    selected("FOO_QBE_TCC", if fileExists(local): local else: "tcc.exe")
  else:
    selected("FOO_QBE_CC", "cc")

proc identity*(): tuple[qbe, cc: string] =
  result = (qbe(), cc())
