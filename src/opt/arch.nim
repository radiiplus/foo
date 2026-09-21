import std/tables
import std/strutils

type
  Profile* = object
    arch*: string
    cpu*: string
    features*: seq[string]
    vector*: int
    call*: int
    multiply*: int
    divide*: int
    budget*: int
    c*: seq[string]
    zig*: string

proc makeProfile(arch, cpu: string; features: seq[string]; vector: int; call = 8; multiply = 3; divide = 12; c: seq[string]; zig: string): Profile =
  Profile(arch: arch, cpu: cpu, features: features, vector: vector, call: call,
    multiply: multiply, divide: divide, budget: 64, c: c, zig: zig)

let profiles* = {
  "x86-64": makeProfile("x86_64", "x86-64", @["sse", "sse2"], 128, c = @["-march=x86-64"], zig = "x86_64"),
  "x86-64-v2": makeProfile("x86_64", "x86-64-v2", @["sse", "sse2", "sse3", "ssse3", "sse4.1", "sse4.2"], 128, c = @["-march=x86-64-v2"], zig = "x86_64_v2"),
  "x86-64-v3": makeProfile("x86_64", "x86-64-v3", @["sse2", "avx", "avx2", "fma", "bmi2"], 256, call = 10, c = @["-march=x86-64-v3"], zig = "x86_64_v3"),
  "x86-64-v4": makeProfile("x86_64", "x86-64-v4", @["sse2", "avx", "avx2", "avx512f", "avx512bw", "avx512dq", "avx512vl"], 512, call = 10, c = @["-march=x86-64-v4"], zig = "x86_64_v4"),
  "arm64": makeProfile("aarch64", "arm64", @["neon"], 128, call = 10, multiply = 2, c = @["-march=armv8-a"], zig = "generic"),
  "apple_m1": makeProfile("aarch64", "apple_m1", @["neon"], 128, call = 10, multiply = 2, c = @["-mcpu=apple-m1"], zig = "apple_m1"),
  "arm64-sve": makeProfile("aarch64", "arm64-sve", @["neon", "sve"], 0, call = 10, multiply = 2, c = @["-march=armv8.2-a+sve"], zig = "generic+sve"),
  "rv64g": makeProfile("riscv64", "rv64g", @["i", "m", "a", "f", "d", "zicsr", "zifencei"], 0, call = 6, divide = 16, c = @["-march=rv64g", "-mabi=lp64d"], zig = "generic_rv64+m+a+f+d+zicsr+zifencei"),
  "rv64gcv": makeProfile("riscv64", "rv64gcv", @["i", "m", "a", "f", "d", "c", "v", "zicsr", "zifencei"], 0, call = 6, divide = 16, c = @["-march=rv64gcv", "-mabi=lp64d"], zig = "generic_rv64+m+a+f+d+c+v+zicsr+zifencei")
}.toTable

proc architecture*(target = ""): string =
  var arch = if target.len > 0: target.split('-')[0] else: hostCPU
  case arch
  of "x64", "amd64": "x86_64"
  of "arm64": "aarch64"
  of "linux", "windows": (if target.contains("arm64"): "aarch64" else: "x86_64")
  of "macos": (if target.contains("x64"): "x86_64" else: "aarch64")
  else: arch

proc profile*(target = ""; cpu = ""): Profile =
  let arch = architecture(target)
  let defaultCpu = case arch
    of "x86_64": "x86-64"
    of "aarch64": "arm64"
    of "riscv64": "rv64g"
    else: ""
  var chosen = if cpu.len == 0 or cpu == "generic": defaultCpu else: cpu
  case chosen
  of "baseline": chosen = defaultCpu
  of "x86-64-baseline", "x86_64": chosen = "x86-64"
  of "x86_64_v2": chosen = "x86-64-v2"
  of "x86_64_v3": chosen = "x86-64-v3"
  of "x86_64_v4": chosen = "x86-64-v4"
  of "aarch64": chosen = "arm64"
  else: discard
  if chosen notin profiles:
    if cpu.len > 0 and cpu != "generic":
      var choices: seq[string]
      for item in profiles.values:
        if item.arch == arch: choices.add(item.cpu)
      raise newException(ValueError, "Unknown CPU '" & cpu & "'. Choose " & (if choices.len > 0: choices.join(", ") else: "generic"))
    return Profile(arch: arch, cpu: "generic", call: 8, multiply: 3, divide: 12, budget: 64, zig: "generic")
  result = profiles[chosen]
  if result.arch != arch:
    raise newException(ValueError, "CPU '" & cpu & "' requires " & result.arch & "; the selected target is " & arch)
