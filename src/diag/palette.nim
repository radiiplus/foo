import std/strutils

type PaletteEntry* = tuple[hex: string, fallback: int]

const palette* = [
  (role: "info", entry: (hex: "61DAFB", fallback: 34)),
  (role: "debug", entry: (hex: "A78BFA", fallback: 35)),
  (role: "warn", entry: (hex: "FFB000", fallback: 33)),
  (role: "error", entry: (hex: "FF3864", fallback: 31)),
  (role: "fatal", entry: (hex: "FF1744", fallback: 91)),
  (role: "success", entry: (hex: "39FF88", fallback: 32)),
  (role: "muted", entry: (hex: "8A9099", fallback: 90))
]

proc shade*(role: string; depth = 1): string =
  var selected: PaletteEntry
  var found = false
  for item in palette:
    if item.role == role: selected = item.entry; found = true; break
  if not found: raise newException(KeyError, "unknown palette role: " & role)
  if depth >= 24:
    let red = parseHexInt(selected.hex[0 .. 1])
    let green = parseHexInt(selected.hex[2 .. 3])
    let blue = parseHexInt(selected.hex[4 .. 5])
    return "\e[38;2;" & $red & ";" & $green & ";" & $blue & "m"
  "\e[" & $selected.fallback & "m"
