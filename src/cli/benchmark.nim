import std/[algorithm, json, monotimes, os, osproc, sequtils, strutils, tables, times]
import ../build/project as construction
import ../build/options

type
  Workload* = object
    name*: string
    file*: string
  Sample* = object
    passed*: bool
    elapsedMs*: float
    error*: string
    metrics*: JsonNode
  Measure* = proc(suite: Workload): Sample {.closure.}
  Measurement* = object
    suite*: Workload
    warmup*: int
    iterations*: int
    samplesMs*: seq[float]
    metricsSamples*: seq[JsonNode]
    minimumMs*: float
    medianMs*: float
    meanMs*: float
    maximumMs*: float
    percentile95Ms*: float
    compilationMs*: float
    cached*: bool
    metrics*: JsonNode
    optimization*: JsonNode
    error*: string

proc discover*(root = getCurrentDir(); filter = ""): seq[Workload] =
  let directory = absolutePath(root / "benchmark")
  if not dirExists(directory): return @[]
  proc label(relative: string): string =
    result = relative[0 ..< relative.len - 3]
    if result.startsWith("workloads/"):
      result = result["workloads/".len .. ^1]
    elif result.startsWith("compilation/fixtures/"):
      result = "compilation/" & result["compilation/fixtures/".len .. ^1]
  if filter.toLowerAscii().endsWith(".iv"):
    var selected = if isAbsolute(filter): absolutePath(filter)
      else: absolutePath(root / filter)
    if not fileExists(selected) and not isAbsolute(filter):
      selected = absolutePath(directory / filter)
    if not fileExists(selected) and not isAbsolute(filter):
      let requested = filter.replace('\\', '/')
      let leaf = if requested.startsWith("benchmark/"):
          requested["benchmark/".len .. ^1]
        else: requested
      if '/' notin leaf:
        let relocated = absolutePath(directory / "workloads" / leaf)
        if fileExists(relocated): selected = relocated
      elif leaf.startsWith("compilation/") and
          '/' notin leaf["compilation/".len .. ^1]:
        let relocated = absolutePath(directory / "compilation" / "fixtures" /
          leaf["compilation/".len .. ^1])
        if fileExists(relocated): selected = relocated
    let relative = relativePath(selected, directory).replace('\\', '/')
    if relative == ".." or relative.startsWith("../"):
      raise newException(ValueError,
        "Benchmark file must be inside benchmark/: " & filter)
    if not fileExists(selected):
      raise newException(ValueError, "Benchmark file not found: " & filter)
    return @[Workload(
      name: label(relative), file: selected)]
  var suites: seq[Workload]
  proc visit(path: string) =
    for kind, child in walkDir(path):
      let name = child.lastPathPart
      if kind in {pcLinkToDir, pcLinkToFile}: continue
      if kind == pcDir:
        if name notin [".artifacts", ".git", "node_modules"] and
            not fileExists(child / "project.ivc"):
          visit(child) # Independently configured projects have their own runner/arguments.
      elif kind == pcFile and child.toLowerAscii().endsWith(".iv"):
        let relative = relativePath(child, directory).replace('\\', '/')
        let name = label(relative)
        if filter.len == 0 or filter in name:
          suites.add(Workload(name: name, file: absolutePath(child)))
  visit(directory)
  suites.sort(proc(left, right: Workload): int = cmp(left.name, right.name))
  result = suites

proc measure(artifact, root: string): Sample {.noinline.} =
  result.metrics = newJObject()
  let existed = existsEnv("FOO_BENCHMARK_METRICS")
  let previous = getEnv("FOO_BENCHMARK_METRICS")
  putEnv("FOO_BENCHMARK_METRICS", "1")
  let started = getMonoTime()
  let execution = execCmdEx(quoteShell(artifact), workingDir = root)
  result.elapsedMs = (getMonoTime() - started).inNanoseconds.float / 1_000_000
  if existed: putEnv("FOO_BENCHMARK_METRICS", previous)
  else: delEnv("FOO_BENCHMARK_METRICS")
  result.passed = execution.exitCode == 0
  if execution.output.len > 0:
    for line in execution.output.splitLines:
      if line.startsWith("FOO_METRICS "):
        try: result.metrics = parseJson(line[12 .. ^1])
        except JsonParsingError: discard
  if not result.passed:
    result.error = if execution.output.len > 0: execution.output
      else: "Benchmark process exited with " & $execution.exitCode

proc summarize(result: var Measurement) =
  if result.samplesMs.len == 0: return
  var ordered = result.samplesMs
  ordered.sort()
  result.minimumMs = ordered[0]
  result.maximumMs = ordered[^1]
  let rank95 = (95 * ordered.len + 99) div 100
  result.percentile95Ms = ordered[max(0, rank95 - 1)]
  let middle = ordered.len div 2
  result.medianMs = if ordered.len mod 2 == 0:
      (ordered[middle - 1] + ordered[middle]) / 2
    else: ordered[middle]
  for sample in ordered: result.meanMs += sample
  result.meanMs /= ordered.len.float

proc benchmark*(root = getCurrentDir(); filter = ""; backend = "qbe";
    warmup = 1; iterations = 10; executor: Measure = nil;
    progress: Observer = nil; mode = ""): seq[Measurement] =
  if backend != "qbe": raise newException(ValueError, "Benchmarks execute QBE")
  if warmup < 0: raise newException(ValueError, "Benchmark warmup cannot be negative")
  if iterations < 1: raise newException(ValueError, "Benchmark iterations must be at least 1")
  let workspace = absolutePath(root)
  let suites = discover(workspace, filter)
  if progress != nil:
    if executor == nil:
      for stage in ["Source", "Compilation"]:
        progress("plan", stage, $suites.len, false)
    progress("plan", "Measurement", $(suites.len * (warmup + iterations)), false)
  for suite in suites:
    var artifact = ""
    var measured = Measurement(suite: suite, warmup: warmup,
      iterations: iterations, metrics: newJObject(),
      optimization: newJObject())
    if executor == nil:
      let started = getMonoTime()
      var reused = false
      let reporter: Observer = proc(phase, name, detail: string; cached: bool) =
        if phase == "reuse" or cached: reused = true
        if progress != nil: progress(phase, name, detail, cached)
      let project = construction.project(workspace,
        construction.Settings(backend: backend, target: construction.host,
          mode: mode, benchmark: true, progress: reporter))
      let products = project.build(suite.file)
      measured.compilationMs = (getMonoTime() - started).inNanoseconds.float / 1_000_000
      measured.cached = reused
      if products.len != 1:
        raise newException(ValueError,
          "Benchmark '" & suite.name & "' must build one executable")
      artifact = products.values.toSeq()[0]
      let facts = parentDir(artifact) / "optimization.json"
      if fileExists(facts): measured.optimization = parseJson(readFile(facts))

    for _ in 0 ..< warmup:
      if progress != nil: progress("sample", suite.name, "", false)
      let sample = if executor != nil: executor(suite)
        else: measure(artifact, workspace)
      if not sample.passed:
        measured.error = sample.error
        break
      if progress != nil: progress("sampled", suite.name, "", false)
    if measured.error.len == 0:
      for _ in 0 ..< iterations:
        if progress != nil: progress("sample", suite.name, "", false)
        let sample = if executor != nil: executor(suite)
          else: measure(artifact, workspace)
        if not sample.passed:
          measured.error = sample.error
          break
        if progress != nil: progress("sampled", suite.name, "", false)
        if sample.metrics != nil: measured.metrics = sample.metrics
        measured.metricsSamples.add(if sample.metrics != nil: sample.metrics else: newJObject())
        measured.samplesMs.add(sample.elapsedMs)
    measured.summarize()
    result.add(measured)
