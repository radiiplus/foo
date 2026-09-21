import std/[json, os, strutils]
import ../build/planner
import ../diag/palette

type
  ProgressPhase* = enum
    ppCheck = "check", ppBuild = "build", ppReuse = "reuse", ppDone = "done"
  Progress* = object
    phase*: ProgressPhase
    name*: string
    file*: string
    cached*: bool
    elapsed*: float
    stages*: seq[Step]

proc display*(jsonOutput = false; verbose = false): proc(event: Progress) {.closure.} =
  let color = getEnv("NO_COLOR").len == 0 and getEnv("TERM") != "dumb"
  proc paint(value, role: string): string =
    if color: shade(role) & value & "\e[0m" else: value
  result = proc(event: Progress) =
    if jsonOutput:
      var stages = newJArray()
      for stage in event.stages:
        stages.add(%*{"name": stage.name, "reused": stage.reused, "elapsed": stage.elapsed})
      let node = %*{"event": "build", "phase": $event.phase, "name": event.name,
        "file": event.file, "cached": event.cached, "elapsed": event.elapsed, "stages": stages}
      stdout.writeLine($node)
      return
    case event.phase
    of ppCheck: stderr.writeLine("  " & paint("Checking", "info") & " " & event.name)
    of ppBuild: stderr.writeLine("  " & paint("Building", "info") & " " & event.name)
    of ppReuse: discard
    of ppDone:
      if verbose:
        for stage in event.stages:
          stderr.writeLine("    " & paint(stage.name, "debug") & ": " &
            (if stage.reused: "reused" else: "ran") & ", " & formatFloat(stage.elapsed, ffDecimal, 1) & " ms")
      let duration = if event.elapsed < 1000: $int(event.elapsed + 0.5) & " ms" else: formatFloat(event.elapsed / 1000, ffDecimal, 2) & " s"
      let location = if event.file.len == 0: "" else: relativePath(getCurrentDir(), event.file)
      stderr.writeLine("  " & paint(if event.cached: "Reused" else: "Built", "success") & " " &
        event.name & " " & paint("- " & duration, "muted"))
      if location.len > 0: stderr.writeLine("    " & paint(location, "muted"))
