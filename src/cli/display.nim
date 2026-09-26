import std/[json, os, strutils, terminal, times]
import ../build/planner
import ../build/options
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
  OperationState* = enum
    stateWorking, stateComplete, stateFailed, stateAttention, stateSkipped
  OperationTask = object
    stage: string
    name: string
    detail: string
    state: OperationState
  Operation* = ref object
    name: string
    jsonOutput: bool
    explain: bool
    interactive: bool
    color: bool
    started: float
    lastRender: float
    frame: int
    renderedLines: int
    tasks: seq[OperationTask]
    finished: bool

proc paint(operation: Operation; value, role: string): string =
  if operation.color: shade(role) & value & "\e[0m" else: value

proc duration(value: float): string =
  if value < 1: $int(value * 1000 + 0.5) & " ms"
  elif value < 60: formatFloat(value, ffDecimal, 1) & " s"
  else: $((int(value)) div 60) & "m " & $((int(value)) mod 60) & "s"

proc clip(value: string; limit: int): string =
  if value.len <= limit: return value
  if limit <= 3: return value[0 ..< max(0, limit)]
  value[0 ..< limit - 3] & "..."

proc wrap(value: string; width: int): seq[string] =
  var offset = 0
  while offset < value.len:
    let count = min(width, value.len - offset)
    result.add(value[offset ..< offset + count])
    offset += count

proc glyph(operation: Operation; state: OperationState): string =
  case state
  of stateWorking: operation.paint("◐", "info")
  of stateComplete: operation.paint("✓", "success")
  of stateFailed: operation.paint("✕", "error")
  of stateAttention: operation.paint("!", "warn")
  of stateSkipped: operation.paint("·", "muted")

proc accent(operation: Operation): string =
  if operation.name in ["BUILD", "CHECK", "RUN", "TOOLCHAIN"]: "debug" else: "info"

proc snapshot(operation: Operation; complete = false; successful = true;
    summary = ""): seq[string] =
  let width = if operation.interactive: max(44, min(100, terminalWidth())) else: 80
  result.add(operation.paint("FOO / " & operation.name, operation.accent()))
  var stages: seq[string]
  for task in operation.tasks:
    if task.stage notin stages: stages.add(task.stage)
  for stage in stages:
    result.add("")
    result.add("  " & operation.paint(stage, operation.accent()))
    var indexes: seq[int]
    for index, task in operation.tasks:
      if task.stage == stage: indexes.add(index)
    for position, index in indexes:
      let task = operation.tasks[index]
      let branch = if position == indexes.high: "└─ " else: "├─ "
      if task.detail.len > max(28, width div 2):
        let available = width - 7
        result.add("  " & clip(branch & task.name, available).alignLeft(available) &
          "  " & operation.glyph(task.state))
        for line in wrap(task.detail, width - 7):
          result.add("     " & operation.paint(line, "muted"))
      else:
        let detail = if task.detail.len > 0: "  " & task.detail else: ""
        let suffixWidth = detail.len + 3
        let available = max(10, width - 4 - suffixWidth)
        let label = clip(branch & task.name, available)
        result.add("  " & label.alignLeft(available) &
          (if detail.len > 0: operation.paint(detail, "muted") else: "") &
          "  " & operation.glyph(task.state))
  result.add("")
  let filled = if complete: 8 else: operation.frame mod 8 + 1
  let blocks = repeat("▰", filled) & repeat("▱", 8 - filled)
  let timing = if complete: " 100%" else:
    " " & now().format("HH:mm:ss") & " · " & duration(epochTime() - operation.started)
  result.add("  " & operation.paint(blocks, if complete and successful: "success" else: operation.accent()) & timing)
  if complete:
    result.add("")
    result.add("  " & operation.paint(operation.name &
      (if successful: " COMPLETE" else: " FAILED"),
      if successful: "success" else: "error"))
    let finalSummary = summary & (if summary.len > 0: " · " else: "") &
      duration(epochTime() - operation.started)
    result.add("  " & finalSummary)

proc render(operation: Operation; force = false; complete = false;
    successful = true; summary = "") =
  if operation.jsonOutput or (not operation.interactive and not force): return
  let current = epochTime()
  if operation.interactive and not force and operation.lastRender > 0 and
      current - operation.lastRender < 0.08: return
  let lines = operation.snapshot(complete, successful, summary)
  if operation.interactive and operation.renderedLines > 0:
    stderr.write("\e[" & $operation.renderedLines & "A\r\e[J")
  stderr.write(lines.join("\n") & "\n")
  stderr.flushFile()
  operation.renderedLines = lines.len
  operation.lastRender = current

proc newOperation*(name: string; jsonOutput = false; explain = false): Operation =
  result = Operation(name: name.toUpperAscii(), jsonOutput: jsonOutput,
    explain: explain, interactive: not jsonOutput and isatty(stderr),
    color: getEnv("NO_COLOR").len == 0 and getEnv("TERM") != "dumb",
    started: epochTime())
  result.render()

proc update*(operation: Operation; stage, name: string; state: OperationState;
    detail = ""; alwaysShowDetail = false) =
  if operation == nil or operation.finished: return
  inc operation.frame
  let visibleDetail = if operation.explain or alwaysShowDetail: detail else: ""
  for task in operation.tasks.mitems:
    if task.stage == stage and task.name == name:
      task.state = state
      if visibleDetail.len > 0: task.detail = visibleDetail
      operation.render()
      return
  operation.tasks.add(OperationTask(stage: stage, name: name,
    detail: visibleDetail, state: state))
  operation.render()

proc completeStage(operation: Operation; stage: string) =
  for task in operation.tasks.mitems:
    if task.stage == stage and task.state == stateWorking:
      task.state = stateComplete

proc failWorking(operation: Operation) =
  for index in countdown(operation.tasks.high, 0):
    if operation.tasks[index].state == stateWorking:
      operation.tasks[index].state = stateFailed
      return

proc report*(operation: Operation; phase, name, detail: string; cached = false) =
  if operation == nil or operation.finished: return
  if operation.jsonOutput:
    if phase != "tick":
      echo $(%*{"event": phase, "name": name, "file": detail, "cached": cached})
    return
  case phase
  of "check": operation.update("Source", name, stateWorking, detail)
  of "checked": operation.update("Source", name, stateComplete)
  of "build": operation.update("Compilation", name, stateWorking)
  of "path": operation.update("Compilation", "path", stateComplete, detail, true)
  of "tick":
    inc operation.frame
    operation.render()
  of "done": operation.update("Compilation", name, stateComplete)
  of "link":
    operation.completeStage("Compilation")
    operation.update("Linking", name, stateWorking, detail)
  of "linked": operation.update("Linking", name, stateComplete, detail)
  of "failed":
    operation.failWorking()
    operation.render()
  of "reuse": operation.update("Compilation", name, stateComplete,
    "project cache", true)
  of "package": operation.update("Preparing", "metadata", stateComplete, detail)
  of "bundle": operation.update("Preparing", "source bundle", stateComplete, detail)
  of "upload": operation.update("Publishing", "registry", stateWorking, detail)
  of "commit":
    operation.completeStage("Publishing")
    operation.update("Publishing", name, stateComplete, detail)
  of "resolve": operation.update("Resolving", name, stateWorking, detail)
  of "fetch":
    operation.completeStage("Resolving")
    operation.update("Downloading", name, stateWorking, detail)
  of "install":
    operation.update("Downloading", name, stateComplete)
    operation.update("Installing", name, stateComplete, detail)
  of "locked":
    operation.completeStage("Resolving")
    operation.update("Resolving", name, stateComplete, detail)
  of "lock": operation.update("Installing", name, stateComplete, detail)
  of "remove": operation.update("Removing", name, stateComplete, detail)
  of "download": operation.update("Downloading", name, stateWorking, detail, true)
  of "downloaded": operation.update("Downloading", name, stateComplete, detail, true)
  of "verify": operation.update("Verifying", name, stateWorking, detail)
  of "verified": operation.update("Verifying", name, stateComplete, detail)
  of "extract": operation.update("Installing", "archive", stateWorking, detail)
  of "ready":
    operation.completeStage("Installing")
    operation.update("Toolchain", name, stateComplete, detail)
  else: operation.update(phase.capitalizeAscii(), name, stateComplete, detail)

proc reporter*(operation: Operation): BuildProgress =
  result = proc(phase, name, detail: string; cached: bool) =
    operation.report(phase, name, detail, cached)

proc finish*(operation: Operation; successful = true; summary = "") =
  if operation == nil or operation.finished: return
  if successful:
    for task in operation.tasks.mitems:
      if task.state == stateWorking: task.state = stateComplete
  else:
    operation.failWorking()
  operation.finished = true
  if operation.jsonOutput:
    echo $(%*{"event": "complete", "operation": operation.name,
      "success": successful, "summary": summary,
      "elapsed": epochTime() - operation.started})
  else:
    operation.render(force = true, complete = true, successful = successful,
      summary = summary)

proc isFinished*(operation: Operation): bool =
  operation == nil or operation.finished

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
