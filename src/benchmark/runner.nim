import std/[algorithm, json, monotimes, os, osproc, sequtils, strutils, tables, times]
import ../build/project as buildProject
import ../build/options

type
  BenchmarkSuite* = object
    name*: string
    file*: string
  BenchmarkSample* = object
    passed*: bool
    elapsedMs*: float
    error*: string
    metrics*: JsonNode
  BenchmarkExecutor* = proc(suite: BenchmarkSuite): BenchmarkSample {.closure.}
  BenchmarkResult* = object
    suite*: BenchmarkSuite
    warmup*: int
    iterations*: int
    samplesMs*: seq[float]
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

proc discoverBenchmarks*(root = getCurrentDir(); filter = ""): seq[BenchmarkSuite] =
  let directory = absolutePath(root / "benchmark")
  if not dirExists(directory): return @[]
  if filter.toLowerAscii().endsWith(".iv"):
    var selected = if isAbsolute(filter): absolutePath(filter)
      else: absolutePath(root / filter)
    if not fileExists(selected) and not isAbsolute(filter):
      selected = absolutePath(directory / filter)
    let relative = relativePath(selected, directory).replace('\\', '/')
    if relative == ".." or relative.startsWith("../"):
      raise newException(ValueError,
        "Benchmark file must be inside benchmark/: " & filter)
    if not fileExists(selected):
      raise newException(ValueError, "Benchmark file not found: " & filter)
    return @[BenchmarkSuite(
      name: relative[0 ..< relative.len - 3], file: selected)]
  var suites: seq[BenchmarkSuite]
  proc visit(path: string) =
    for kind, child in walkDir(path):
      let name = child.lastPathPart
      if kind in {pcLinkToDir, pcLinkToFile}: continue
      if kind == pcDir:
        if name notin [".artifacts", ".git", "node_modules"]: visit(child)
      elif kind == pcFile and child.toLowerAscii().endsWith(".iv"):
        let relative = relativePath(child, directory).replace('\\', '/')
        let suiteName = relative[0 ..< relative.len - 3]
        if filter.len == 0 or filter in suiteName:
          suites.add(BenchmarkSuite(name: suiteName, file: absolutePath(child)))
  visit(directory)
  suites.sort(proc(left, right: BenchmarkSuite): int = cmp(left.name, right.name))
  result = suites

proc measureArtifact(artifact, root: string): BenchmarkSample {.noinline.} =
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

proc summarize(result: var BenchmarkResult) =
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

proc runBenchmarks*(root = getCurrentDir(); filter = ""; backend = "zig";
    warmup = 1; iterations = 10; executor: BenchmarkExecutor = nil;
    progress: BuildProgress = nil; mode = ""): seq[BenchmarkResult] =
  if warmup < 0: raise newException(ValueError, "Benchmark warmup cannot be negative")
  if iterations < 1: raise newException(ValueError, "Benchmark iterations must be at least 1")
  let projectRoot = absolutePath(root)
  for suite in discoverBenchmarks(projectRoot, filter):
    var artifact = ""
    var measured = BenchmarkResult(suite: suite, warmup: warmup,
      iterations: iterations, metrics: newJObject(),
      optimization: newJObject())
    if executor == nil:
      let started = getMonoTime()
      var reused = false
      let reporter: BuildProgress = proc(phase, name, detail: string; cached: bool) =
        if phase == "reuse" or cached: reused = true
        if progress != nil: progress(phase, name, detail, cached)
      let project = buildProject.newProject(projectRoot,
        buildProject.ProjectOptions(backend: backend, target: buildProject.host,
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
      let sample = if executor != nil: executor(suite)
        else: measureArtifact(artifact, projectRoot)
      if not sample.passed:
        measured.error = sample.error
        break
    if measured.error.len == 0:
      for _ in 0 ..< iterations:
        let sample = if executor != nil: executor(suite)
          else: measureArtifact(artifact, projectRoot)
        if not sample.passed:
          measured.error = sample.error
          break
        if sample.metrics != nil: measured.metrics = sample.metrics
        measured.samplesMs.add(sample.elapsedMs)
    measured.summarize()
    result.add(measured)
