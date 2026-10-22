const hardware* = "Hardware-level projects on Windows require WSL 2."
let levels* = ["base", "system", "machine", "hardware"]

proc ensure*(level: string) =
  if level notin levels:
    raise newException(ValueError, "Unknown capability '" & level & "'")
  if level == "hardware" and defined(windows):
    raise newException(ValueError, hardware)
